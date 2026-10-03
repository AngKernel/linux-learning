# A3 拷贝的代价与零拷贝的演进

基准：Linux v6.18，`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`。下列源码行号均对应这个版本。源码事实、提交作者的解释、本文推断分别标明；实验方案尚未运行。

## 1. 问题：省掉复制之后，谁负责数据的生命周期？

普通 TCP 发送把应用数据复制到内核拥有的存储中；普通接收把内核收到的数据复制到应用给出的地址。这不仅花 CPU 周期，还消耗内存带宽、占用缓存。应用随后再把数据搬到 GPU 时，又多一段主机内存与设备之间的搬运。

但复制同时提供了一个有价值的边界：发送返回后，应用可以改写已经被接收的那部分发送缓冲区；内核仍拥有可用于重传的稳定副本。接收复制结束后，驱动缓冲区与应用缓冲区的生命期也能分开。

所以设计问题不是简单地删掉 `memcpy`，而是：**怎样在不丢失可靠传输、内存隔离和资源回收能力的前提下，把复制换成共享？** 不解决这些问题，轻则提前复用缓冲区破坏自己的数据，重则长期占住接收队列或页资源，让其他流也无法前进。

当前复制位置可直接核查：发送在 [net/ipv4/tcp.c:1243](../../../src/linux-6.18/net/ipv4/tcp.c:1243) 的普通分支，经 `skb_copy_to_page_nocache()` 复制到 page frag；接收在 [net/ipv4/tcp.c:2822](../../../src/linux-6.18/net/ipv4/tcp.c:2822) 调 `skb_copy_datagram_msg()`。前者说明“普通发送要复制”并不等于“整个包被放进一个连续大缓冲区”。参见 [A1](A1-sk_buff.md)。

## 2. 约束：通用 socket API 不能默认要求应用替内核管理页

1. **兼容旧程序。** 文档说明，历史上未知 send flags 可能被忽略；不能仅凭某个新增 bit 就改变旧程序的缓冲区生命期。因此普通 syscall 接口要求先用 `SO_ZEROCOPY` 明确选择，再在每次发送时加 `MSG_ZEROCOPY`。[Documentation/networking/msg_zerocopy.rst:65](../../../src/linux-6.18/Documentation/networking/msg_zerocopy.rst:65)
2. **TCP 可靠性。** 发送成功只是内核接收了数据；丢包重传仍可能读原缓冲区。NIC 发完一次不代表 TCP 再也不需要它。
3. **隔离与有限内存。** 任意进程不能无限持有不可回收的页。普通发送零拷贝在 `mm_account_pinned_pages()` 中按用户计入 `locked_vm`，受 `RLIMIT_MEMLOCK` 和权限条件约束；还有完成通知与 socket 记账成本。[net/core/skbuff.c:1616](../../../src/linux-6.18/net/core/skbuff.c:1616)
4. **NIC 与路径不同。** 分散聚集、校验和、header split、DMA 可达性不是所有设备都有；loopback、抓包、软件处理还可能要求 CPU 读取载荷。
5. **页不是任意粒度的安全容器。** 把半页载荷连同其他数据一起映射给用户，会跨越所有权边界。页映射路线必须严格检查布局与来源。
6. **应用种类不同。** 数百字节 RPC、数 MiB 文件、GPU 间训练流量的最优接口不同。Linux 保留普通复制接口，再增加可选择的专用路线。

最后一条是从接口共存和后述演进得出的设计分析，不是某一提交对所有工作负载作出的保证。

## 3. 方案：先分清四种“零拷贝”

| 路线 | 省掉哪一段复制 | 数据存放与交付方式 | 应用何时可复用资源 | 主要条件 |
|---|---|---|---|---|
| `MSG_ZEROCOPY` 发送 | 应用内存 → 内核发送载荷副本 | skb 引用应用页 | 收到对应范围的 error queue 完成通知 | 显式选择；路径支持；大块写入通常更合适 |
| `TCP_ZEROCOPY_RECEIVE` | 内核接收页 → 应用缓冲区 | 把合格的接收页映射进 TCP VMA | 应用读完后撤销/替换映射；不再保留旧指针 | MMU；整页、对齐且来源合格；不合格部分复制 |
| io_uring ZC Rx | 内核接收缓冲区 → 用户页 | NIC DMA 到预注册内存；CQE 返回位置 | 应用消费完后通过 refill ring 归还 | 专用 RX 队列、header split、流转向、驱动支持 |
| devmem TCP | 经主机 RAM 中转的设备载荷搬运 | NIC 与 dma-buf 对应设备存储直接传输；TCP 头仍由内核处理 | RX 归还 token；TX 等待 error queue 完成通知 | dma-buf、设备/驱动配合、DMA 可达性；RX 还需拆头与队列隔离 |

这里的“零”针对表中那段载荷复制。协议头构造、控制消息复制、引用计数、TCP 状态机和队列工作仍存在。

### 3.1 发送：用页引用和完成通知代替内核副本

在 [net/ipv4/tcp.c:1102](../../../src/linux-6.18/net/ipv4/tcp.c:1102)，`tcp_sendmsg_locked()` 检查请求、完成通知对象和 `NETIF_F_SG`。普通 socket syscall 路线由 `SOCK_ZEROCOPY` 选择；`msg->msg_ubuf` 是另一个由内核调用者提供通知对象的入口，不要把两者混为一谈。

随后，[net/ipv4/tcp.c:1288](../../../src/linux-6.18/net/ipv4/tcp.c:1288) 调 `skb_zerocopy_iter_stream()`；它在 [net/core/skbuff.c:1846](../../../src/linux-6.18/net/core/skbuff.c:1846) 调 `__zerocopy_sg_from_iter()`。普通用户内存分支最终由 `zerocopy_fill_skb_from_iter()` 通过 `iov_iter_get_pages2()` 取得页引用并填充 skb frags。[net/core/datagram.c:635](../../../src/linux-6.18/net/core/datagram.c:635)

关键字段见 [include/linux/skbuff.h:546](../../../src/linux-6.18/include/linux/skbuff.h:546)：

- `ubuf_info.refcnt` 与 `ops->complete`：聚合共享这批用户数据的引用，最后完成时通知。
- `ubuf_info_msgzc.id/len`：发送调用编号和连续编号数量；编号不是字节序号。
- `ubuf_info_msgzc.zerocopy`：是否仍满足无复制完成条件。
- `ubuf_info_msgzc.mmp`：该用户的页额度记账。
- `skb_shared_info.destructor_arg`：关联完成通知对象，见 [include/linux/skbuff.h:620](../../../src/linux-6.18/include/linux/skbuff.h:620)。

生命周期可以按下面读：

```text
send 接收了 N 字节
  → skb 引用这 N 字节对应的用户页；应用暂不能改写
  → TCP / 下层继续使用，可能重传，可能发生复制回退
  → 不再需要原用户页
  → error queue 给出调用编号范围
  → 应用才能回收该范围对应的缓冲区
```

`__msg_zerocopy_callback()` 设置 `SO_EE_ORIGIN_ZEROCOPY`，用 `[ee_info, ee_data]` 表示包含两端的完成范围，并尝试合并相邻通知。存在复制时标记 `SO_EE_CODE_ZEROCOPY_COPIED`。[net/core/skbuff.c:1768](../../../src/linux-6.18/net/core/skbuff.c:1768)

**这份通知确认的是“原缓冲区可以复用”。** 发生复制回退时，它可能早于数据真正发完；即使没有回退，也不能把它解释成远端应用已读取。通知可能因重传、关闭而乱序，应用不能只凭“最后看到的最大编号”盲目释放所有旧缓冲区。文档明确说明这些边界。[Documentation/networking/msg_zerocopy.rst:101](../../../src/linux-6.18/Documentation/networking/msg_zerocopy.rst:101)、[同文件:211](../../../src/linux-6.18/Documentation/networking/msg_zerocopy.rst:211)

文档给出的经验是，写入大于约 10 KB 时才通常值得：节省的是逐字节复制，增加的是逐页记账和通知。这不是硬编码阈值。loopback、本地接收路径以及某些抓包路径会发生延后复制；同机 veth 测试不能直接代表物理 NIC 的收益。[同文件:21](../../../src/linux-6.18/Documentation/networking/msg_zerocopy.rst:21)、[同文件:240](../../../src/linux-6.18/Documentation/networking/msg_zerocopy.rst:240)

另外，io_uring 的发送 ZC 复用这类内核缓冲区引用机制，但用通知 CQE 表达生命期，不是要求应用读取 socket error queue：`io_send_zc()` 提供 `msg_ubuf`，见 [io_uring/net.c:1454](../../../src/linux-6.18/io_uring/net.c:1454)；通知标志见 [include/uapi/linux/io_uring.h:490](../../../src/linux-6.18/include/uapi/linux/io_uring.h:490)。不要将它与下述接收 ZC 混淆。

### 3.2 传统接收零拷贝：移动映射，不移动载荷

当前接口分两步：

1. 对 TCP socket 做只读 `mmap()`，建立 VMA。`tcp_mmap()` 只设置映射属性，不消费接收队列。[net/ipv4/tcp.c:1839](../../../src/linux-6.18/net/ipv4/tcp.c:1839)
2. 调 **`getsockopt(TCP_ZEROCOPY_RECEIVE)`** 请求映射已有数据；内核先持 socket 锁，再进入 `tcp_zerocopy_receive()`。[net/ipv4/tcp.c:4687](../../../src/linux-6.18/net/ipv4/tcp.c:4687)

注意：UAPI 头部 [include/uapi/linux/tcp.h:487](../../../src/linux-6.18/include/uapi/linux/tcp.h:487) 的注释仍写着 `setsockopt`；实际处理分支和 selftest 使用 `getsockopt`。笔记以实现为准。

`struct tcp_zerocopy_receive` 的主要字段在 [include/uapi/linux/tcp.h:490](../../../src/linux-6.18/include/uapi/linux/tcp.h:490)：

| 字段 | 含义 |
|---|---|
| `address` | 已建立的 TCP 映射地址，要求页对齐 |
| `length` | 输入最大映射长度；输出实际映射长度 |
| `recv_skip_hint` | 在下一段可映射数据前，需通过复制消费的字节数，不是让应用丢弃这些字节 |
| `copybuf_address/copybuf_len` | 小块和不对齐尾部的复制缓冲区及实际结果 |
| `inq/err` | 队列数据量与 socket 错误信息 |
| `flags` | 包括“映射已经清理”的 TLB hint |

`can_map_frag()` 要求 frag 大小恰为 `PAGE_SIZE`、页内偏移为 0、不是 compound page、`page->mapping == NULL`。[net/ipv4/tcp.c:1879](../../../src/linux-6.18/net/ipv4/tcp.c:1879) 这不仅是性能条件：最后两个检查防止把不属于预期 NIC 页模型的内存按这种方式映射。

映射路径会清理旧 PTE，批量插入新页，再推进 `tp->copied_seq` 并清理已消费的 TCP 数据。[net/ipv4/tcp.c:2168](../../../src/linux-6.18/net/ipv4/tcp.c:2168) 这是真正的接收操作，不是“只旁观一个可随时再 recv 的副本”。一旦重用或撤销映射，旧地址就不能继续代表旧数据。

为什么并非所有 1500 MTU 流量都受益？TCP 是字节流，页是固定粒度；某个 skb frag 可能含协议头、半页数据或共享布局。header/data split、MTU 或硬件聚合必须让驱动交出合格整页。相关硬件接口说明见 [Documentation/networking/ethtool-netlink.rst:917](../../../src/linux-6.18/Documentation/networking/ethtool-netlink.rst:917)。不能只打开一个 TCP 开关就保证成功。

### 3.3 io_uring ZC Rx：预先决定载荷落点，避免逐次改页表

这里先注册一块内存和一个 NIC RX 队列，再让 NIC 把 TCP 载荷 DMA 到该区域；头部仍在内核正常过 TCP。应用收到 CQE 的长度和 offset，消费后经 refill ring 归还资源。[Documentation/networking/iou-zcrx.rst:10](../../../src/linux-6.18/Documentation/networking/iou-zcrx.rst:10)

相对于传统页映射，它不要求每个 TCP 载荷片段恰好是可映射整页，也不需要为每批数据重映射 PTE。**但注册区域本身仍需页对齐。** `io_import_area()` 明确校验地址与长度，见 [io_uring/zcrx.c:228](../../../src/linux-6.18/io_uring/zcrx.c:228)。文档中的“无严格对齐要求”不能扩展成所有参数都不需要对齐。

代码入口与边界：

- 注册检查 `CAP_NET_ADMIN`、`DEFER_TASKRUN` 和扩展 CQE 格式。[io_uring/zcrx.c:559](../../../src/linux-6.18/io_uring/zcrx.c:559) `DEFER_TASKRUN` 又要求 `SINGLE_ISSUER`。[io_uring/io_uring.c:3706](../../../src/linux-6.18/io_uring/io_uring.c:3706)
- `io_recvzc_prep()` 要求 multishot，并用 `zcrx_ifq_idx` 选择已注册队列。[io_uring/net.c:1241](../../../src/linux-6.18/io_uring/net.c:1241)
- `io_zcrx_tcp_recvmsg()` 仍会 `lock_sock()`，再经 `tcp_read_sock()` 消费数据。[io_uring/zcrx.c:1200](../../../src/linux-6.18/io_uring/zcrx.c:1200) 所以 ZC Rx 并没有自动消除 [B1](B1-socket-lock-backlog.md) 中的并发约束。
- `io_zcrx_recv_frag()` 检查 frag 是否来自本 io_uring 注册的队列；目标为普通注册用户内存（UMEM）时，普通 host page 有复制回退，错误的 net_iov 所属关系会被拒绝。[io_uring/zcrx.c:1068](../../../src/linux-6.18/io_uring/zcrx.c:1068)
- `io_uring_zcrx_cqe.off` 与 CQE `res` 描述数据位置/长度；refill ring 的 offset 经区域及下标校验后才能找到资源。[io_uring/zcrx.c:931](../../../src/linux-6.18/io_uring/zcrx.c:931)、[同文件:754](../../../src/linux-6.18/io_uring/zcrx.c:754)

为什么注册需要权限？引入提交明确说明：**任何被转向该硬件队列的流量，其载荷都会立即对应用可见**，甚至早于应用通过 TCP 接口消费它。因此配置队列归属和流过滤是安全边界，不能把不同租户任意混入该 RX 队列。硬件 RSS、flow steering 和 header split 的条件见 [Documentation/networking/iou-zcrx.rst:17](../../../src/linux-6.18/Documentation/networking/iou-zcrx.rst:17)。

6.18 也支持 `IORING_ZCRX_AREA_DMABUF` 区域，见 [io_uring/zcrx.c:247](../../../src/linux-6.18/io_uring/zcrx.c:247)。这类区域不能套用普通 UMEM 的复制回退：`io_alloc_fallback_niov()` 对 dma-buf 直接返回空，见 [io_uring/zcrx.c:957](../../../src/linux-6.18/io_uring/zcrx.c:957)。它与下面 devmem 的 socket cmsg/token 接口不同；不应仅凭都用了 dma-buf 就认为 API 可以互换。

### 3.4 devmem TCP：载荷甚至不在 CPU 可读的内存中

RX 初始化时，把 dma-buf 绑定到特定 RX 队列，用 header split 把头交给主机，载荷交给设备存储；RSS 将普通流排除出去，再用 flow steering 把目标流导入。绑定的 netlink socket 关闭时解除绑定，避免进程异常退出留下永久配置。[Documentation/networking/devmem.rst:79](../../../src/linux-6.18/Documentation/networking/devmem.rst:79)

应用调用 `recvmsg(..., MSG_SOCK_DEVMEM)` 后：

- 不可读 devmem skb 的线性区中若含有数据，这部分仍复制给应用，并通过 `SCM_DEVMEM_LINEAR` 说明。纯 host skb 则走普通复制分支，没有这类 devmem cmsg。
- 设备载荷通过 `SCM_DEVMEM_DMABUF` 返回 `dmabuf_id`、`frag_offset`、`frag_size`、`frag_token`，不是把设备内存复制进普通 iovec。
- 应用使用完毕后，用 `SO_DEVMEM_DONTNEED` 归还 token。只丢弃 cmsg 或指针不会归还资源。

实现为 `tcp_recvmsg_dmabuf()`，[net/ipv4/tcp.c:2477](../../../src/linux-6.18/net/ipv4/tcp.c:2477)；字段定义见 [include/uapi/linux/uio.h:23](../../../src/linux-6.18/include/uapi/linux/uio.h:23)。`sk_user_frags` 是跟踪应用持有引用的 xarray；释放逻辑见 `sock_devmem_dontneed()`，[net/core/sock.c:1078](../../../src/linux-6.18/net/core/sock.c:1078)。它限制单次输入 token 数与释放 frag 数，注释直接说明要限制内核分配和循环时间。归还不及时则耗尽队列绑定的有限存储，导致丢包。

TX 在 6.18 也已存在：绑定 TX dma-buf 后，使用 `SO_ZEROCOPY`、`MSG_ZEROCOPY` 与 `SCM_DEVMEM_DMABUF`；iov 的 base 表示 dma-buf 内偏移，应用等 error queue 通知后复用数据。`net_devmem_get_binding()` 检查当前路由设备与 binding 设备相同，因为 DMA 地址只对对应设备有效。[net/core/devmem.c:357](../../../src/linux-6.18/net/core/devmem.c:357)

**文档校正：** `devmem.rst` 的 TX 示例使用 `struct dmabuf_tx_cmsg`，当前源码中未确认存在该类型。6.18 实际要求 cmsg 数据为一个 `u32 dmabuf_id`，校验见 [net/core/sock.c:3036](../../../src/linux-6.18/net/core/sock.c:3036)，正确示例见 [tools/testing/selftests/drivers/net/hw/ncdevmem.c:1355](../../../src/linux-6.18/tools/testing/selftests/drivers/net/hw/ncdevmem.c:1355)。不要照旧文档自行构造一个结构体 ABI。

设备载荷不可被 CPU 通常方式读取，也意味着不能任意退回复制路径：loopback 不可用，软件校验和失败，tcpdump/BPF 无法访问这些载荷。头部处理仍在内核，这不意味着现有载荷审计工具仍然完整有效。[Documentation/networking/devmem.rst:380](../../../src/linux-6.18/Documentation/networking/devmem.rst:380) 对网络安全产品，这是一个实际能力边界：需要内容检查的部署，必须决定在何处取得可检查的载荷；仅保留内核 TCP 并不能自动保留 CPU 侧 DPI 能力。这一部署含义是本文推断。

## 4. 演进：复杂度从复制转移到了所有权、锁和页表

以下提交均实际用本仓库 `git show` 阅读过正文；hash 是完整 hash。性能数字仅属于提交中的历史实验，不是本文在 6.18 上的测量，也不应跨行直接相加。

| 提交 / 作者 | 动机与改变 | commit message 的性能数据或限制 |
|---|---|---|
| `f214f915e7db99091f1312c48b30928c1e0c90b7`，Willem de Bruijn，2017，`tcp: enable MSG_ZEROCOPY` | TCP 接入发送零拷贝，支持 TSO/GSO；本地回送复制，避免无界通知延迟 | 两台主机的 10 路 TCP_STREAM：netserver 进程 cycles 最多下降 70%，系统整体最多下降 20%，依报文大小而变。正文另有 64 KB veth 测试 7600→17863 MB，但接收端截断载荷，作者明确称为上界；不可当正常完整收包收益 |
| `93ab6cc69162775201587cc9da00d5016dc890e2`，Eric Dumazet，2018，`tcp: implement mmap() for zero copy receive` | 在能安排整页 TCP 载荷的网络中，以只读映射避免接收复制 | mlx4/CX-3 40 Gbit NIC，MTU 4168（4096 payload + IPv6 40 + TCP 32）：复制约 116–129 µs/MB，映射约 43.5–45.5 µs/MB；吞吐约 32.8–33.9→34.2–34.4 Gbit/s。这是早期 mmap 实现，不是当前两阶段 API 的独立基准 |
| `05255b823a6173525587f29c4e8f1ca33fd7677d`，Eric Dumazet，2018，`tcp: add TCP_ZEROCOPY_RECEIVE support for zerocopy receive` | syzbot 发现 socket 锁与 mmap 锁顺序问题；拆成预留 VMA 与 getsockopt 消费两步，也方便部分成功和 VMA 复用 | 未提供吞吐增益；指出旧实现 16 MB 映射需要 32 KB 临时页指针数组，新实现省掉它 |
| `3763a24c727ecf236358a81ee749e5fcab1c972a`，Arjun Roy，2020，`net-zerocopy: use vm_insert_pages() for tcp rcv zerocopy` | 批量插页，减少连续反复获取同一页表锁及原子操作 | perf 中 spin lock cycles 从几个百分点降到不足 1%；按接收 ZC 次数 / CPU 利用率计，效率约升 6%；正文未给完整硬件配置 |
| `f21a3c48039891c02063fe6dc3c3a2f8f344b345`，Arjun Roy，2020，`net-zerocopy: Introduce short-circuit small reads.` | 小数据直接复制到附带 copy buffer，避免无效 mmap 锁和额外 recvmsg | 数百字节 RPC：每次 3 个 syscall 减为 2 个，syscall 数约减 33%；QPS/CPU 利用率提高约 3–5% |
| `94ab9eb9b234ddf23af04a4bc7e8db68e67b8778`，Arjun Roy，2020，`net-zerocopy: Defer vm zap unless actually needed.` | 应用提示映射已清理时跳过冗余 zap；错误 hint 仍由内核兜底，旧程序保留原行为 | 数十 KB RPC，QPS/CPU 利用率约提高 30%；同时增大插页 batch 并预取 page，不能将全部收益单独归给 hint |
| `577e4432f3ac810049cb7e6b71f4d96ec7c6e894`，Eric Dumazet，2024，`tcp: add sanity checks to rx zerocopy` | syzbot 经 sendfile + loopback 把 ext4 文件页送入接收映射，触发 panic；增加 compound 与 mapping 检查 | 未提供性能数据；提交给出复现和修复依据 |
| `8f0b3cc9a4c102c24808c87f1bc943659d7a7f9f`，Mina Almasry，2024，`tcp: RX path for devmem TCP` | 设备载荷不能普通复制，用 cmsg 表达位置、token 表达待归还引用 | 未提供性能数据。历史正文函数名是 `tcp_recvmsg_devmem`；6.18 当前名为 `tcp_recvmsg_dmabuf` |
| `11ed914bbf948c4a37248f2876973ac18014056d`，David Wei，2025，`io_uring/zcrx: add io_recvzc request` | 将已经 DMA 到用户区的载荷通过 CQE 交付，并核验队列归属 | 未提供性能数据；正文明确队列流量立即对应用可见，因此注册需要 CAP_NET_ADMIN。正文当时说单请求无工作量上限；6.18 已有重排调度限制，不能照抄为当前事实 |
| `a5c98e9424573649e59988199a3356a79c9e1fd9`，Pavel Begunkov，2025，`io_uring/zcrx: dmabuf backed zerocopy receive` | ZC Rx 注册区支持 dma-buf | 未提供性能数据 |
| `bd61848900bff597764238f3a8ec67c815cd316e`，Mina Almasry，2025，`net: devmem: Implement TX path` | 复用 MSG_ZEROCOPY 生命期机制发送 dma-buf，禁用不可行的复制回退；不可睡眠路径通过工作队列延后解除映射 | 未提供性能数据 |

取证过程可复查：

```bash
git log -S 'MSG_ZEROCOPY' -- net/ipv4/tcp.c
git log -S 'TCP_ZEROCOPY_RECEIVE' -- net/ipv4/tcp.c
git log -S 'vm_insert_pages' -- net/ipv4/tcp.c
git log -S 'copybuf_address' -- net/ipv4/tcp.c
git blame -L 1879,1892 -- net/ipv4/tcp.c
git log -S 'MSG_SOCK_DEVMEM' -- net/ipv4/tcp.c
git log -S 'net_devmem_get_binding' -- net/ipv4/tcp.c
git log -S 'IORING_OP_RECV_ZC' -- include/uapi/linux/io_uring.h
git log -S 'IORING_ZCRX_AREA_DMABUF' -- io_uring/zcrx.c
git show -s --format=fuller <上表完整hash>
```

## 5. 取舍：逐字节成本降下去，固定成本和资源耦合升上来

| 场景 | 得到什么 | 付出什么；何时成为负担 |
|---|---|---|
| 大块远端发送 | 减少 CPU 复制和内存流量 | 页引用、额度、通知；RTT 大、丢包多时原缓冲区可能被占更久，应用需要更多在途存储 |
| 小 RPC | 普通复制往往直接结束缓冲区借用 | 逐页和通知成本摊不薄；接收 ZC 专门加入复制捷径正是证据 |
| 整页映射接收 | 保留 TCP 接口与可靠性，绕过载荷复制 | VMA/PTE/TLB 管理与 socket 锁交互；不整页的数据还要混合复制；映射寿命由应用管理 |
| 专用 RX 队列的 io_uring ZC Rx | 避免逐批页表替换，可批量完成/归还 | 队列数量、预注册内存、驱动条件、流转向运维；一个进程的接收池不能任意承接其他租户数据 |
| GPU/存储设备之间传输 | 减少主机 RAM 和 PCIe 中转 | 设备拓扑、dma-buf 生命周期、队列治理更复杂；CPU 无法读取载荷的路径不能完成既有内容检查 |

这些路线都要回答“慢消费者何时归还资源”。TCP 接收窗口只能对传输中的数据施加流控，不能替应用自动释放已经交付但仍持有的映射、token 或注册区引用。生命周期拖延的影响会从一个 socket 扩大到共享 page pool / RX 队列；这是从实现和文档资源边界得出的分析。

发送记账也没有简单消失：`__zerocopy_sg_from_iter()` 仍增加 `sk_wmem_queued`；纯零拷贝是否进入普通协议内存 charge 有专门分支。[net/core/datagram.c:762](../../../src/linux-6.18/net/core/datagram.c:762) 因此 A2 的 TCP memory 统计不能独自代表“应用零拷贝占住的所有页”。

## 6. 对照：同地址空间可以少一层边界，不能省掉生命期

以固定版本 **lwIP 2.1.3 raw TCP API** 为例，官方源码中 `tcp_write()` 不设置 `TCP_WRITE_FLAG_COPY` 时引用调用者数据，要求数据保持不变直到被对端 ACK；若启用 `LWIP_NETIF_TX_SINGLE_PBUF`，代码反而强制复制以满足单缓冲区要求。相关声明、分支和注释已通过源码检索核对。[lwIP 2.1.3 tcp_out.c](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_1_3_RELEASE/src/core/tcp_out.c)

对照的意义是：当应用与栈位于同一地址空间、共同遵守一个缓冲区协议时，可以直接传引用，不必为每次交付建立跨用户/内核的映射和通知 ABI。代价由集成者承担：提前改写或释放数据会破坏传输；设备不接受分散数据时仍得复制。这一比较是依据上述接口约束作出的推断，不代表 lwIP 的所有驱动和 socket 适配层都零拷贝，也不代表 lwIP 必然部署在 Linux 用户态。

对 VPP/DPDK 背景，可以把 Linux 的页引用、完成队列、归还 token 理解为“把显式 buffer ownership 协议加到通用 socket 之上”。不过 DPDK buffer 管理本身不是 TCP，VPP 的共享 FIFO 也不能单凭“共享”二字推出 NIC 到应用全路径没有复制。具体路径的拷贝次数须另查该栈版本与驱动，本篇未确认，故不提供泛化数字。

## 7. 验证：分开测省掉的复制与新增的管理开销

本节是可复现实验方案，未运行，也没有更改本机 NIC/sysctl。应使用运行相应内核的两台测试机，记录 NIC、MTU、offload、CPU/NUMA、消息大小、并发数和应用是否实际读取全部载荷。仅测 sender 进程会漏掉 softirq 和对端成本。

**发送实验。** 使用现有 [tools/testing/selftests/net/msg_zerocopy.c:709](../../../src/linux-6.18/tools/testing/selftests/net/msg_zerocopy.c:709)；其参数已核对。将下例地址替换成测试接收机；每一轮都重新启动接收端。

```bash
# 接收机：普通 TCP 接收；程序已构建并位于当前目录
./msg_zerocopy -4 -r -t 20 tcp

# 发送机：两轮分别运行，第二轮增加 -z
perf stat -e cycles,instructions,cache-misses,context-switches -- \
  ./msg_zerocopy -4 -D 192.0.2.2 -t 10 -s 32768 tcp
perf stat -e cycles,instructions,cache-misses,context-switches -- \
  ./msg_zerocopy -4 -D 192.0.2.2 -t 10 -s 32768 -z tcp
```

用 1 KB、8 KB、32 KB、约 60 KB 写入分别比较 CPU/有效字节，并另用 `perf stat -a` 覆盖同一流量区间，捕获 softirq 总成本。正确性检查另跑一轮，在发送参数中加 `-z -v -v -Z 1`：打印完成编号，并在通知表明发生复制时报告预期不符。不要把大量日志混入性能测量。

这个 selftest **没有直接统计 copied 通知比例**；默认不指定 `-Z` 时，末尾 `zc=n` 也不能解释为实际发生了复制，它取决于预期配置。依据见 [tools/testing/selftests/net/msg_zerocopy.c:447](../../../src/linux-6.18/tools/testing/selftests/net/msg_zerocopy.c:447)、[同文件:575](../../../src/linux-6.18/tools/testing/selftests/net/msg_zerocopy.c:575)。TCP 接收分支用 `MSG_TRUNC` 消费数据，见 [同文件:618](../../../src/linux-6.18/tools/testing/selftests/net/msg_zerocopy.c:618)，所以它适合验证发送与通知机制，不能代表读取/解析全部数据的业务收益。

**映射接收实验。** 使用 [tools/testing/selftests/net/tcp_mmap.c:172](../../../src/linux-6.18/tools/testing/selftests/net/tcp_mmap.c:172)，比较 server `-s` 与 `-s -z`，固定 sender 行为；两边可加 `-i` 进行相同的内容摘要验证。客户端 `-H` 指定对端，`-z` 对客户端意味着发送 ZC，不能把它同时改变后声称只测了接收优化。记录程序输出的 mapped 百分比、µs/MB、吞吐与切换数。mapped 为零首先检查页布局；不要把“调用成功”当成“载荷都映射了”。

**io_uring ZC Rx / devmem。** 采用仓库已有的 [iou-zcrx.c](../../../src/linux-6.18/tools/testing/selftests/drivers/net/hw/iou-zcrx.c) 和 [ncdevmem.c](../../../src/linux-6.18/tools/testing/selftests/drivers/net/hw/ncdevmem.c)。先核对驱动是否支持，按对应本地文档在专用测试队列设置拆头与转向，再比较吞吐、CPU、RX 丢包和归还延迟。不支持这些条件的环境只能验证普通复制路线，不能据此下“零拷贝无效”的结论。
