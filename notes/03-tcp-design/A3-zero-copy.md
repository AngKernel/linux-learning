# A3. 零拷贝：省下搬运后，谁负责缓冲区生命期

本篇回答：发送、接收映射与 devmem 分别省哪次拷贝？为何零拷贝会失败或更慢？前置阅读：A1、A2、虚拟内存映射。预计阅读：12 分钟。源码基准：Linux v6.18。

## 1. 问题

大块 TCP 数据在应用、内核和设备之间搬运会消耗 CPU 与内存带宽。避免搬运后，应用不再拥有一个可立即重写的私有副本，必须等栈不再需要原数据。

## 2. 约束

可靠重传可能晚于第一次 DMA 完成；用户页要记账和保护；接收映射要满足页粒度及来源检查；内核不能读取的设备内存无法任意退回软件复制。旧程序的 send 返回后复用缓冲语义也不能被悄悄改变。

## 3. 方案

| 接口 | 省去的搬运与新责任 | 条件/限制 |
|---|---|---|
| `MSG_ZEROCOPY` | skb 引用应用页；应用等待 error queue 完成通知后复用 | 普通 socket API 要先启用 `SO_ZEROCOPY`；允许复制回退；小写入可能得不偿失 |
| `TCP_ZEROCOPY_RECEIVE` | 将合格接收页映射到应用 VMA；应用负责映射与未映射字节的处理 | 先 `mmap` 预留，再 `getsockopt` 消费；页对齐和页来源限制；小块可复制 |
| devmem TCP RX | NIC 将载荷写进 dma-buf 所代表的设备内存；应用取得位置与 token，处理完归还 | header split、flow steering、RSS 及对应驱动能力；普通内存部分仍可复制 |
| devmem TCP TX | 从绑定的 dma-buf 发包，复用发送零拷贝完成语义 | 必须使用 `MSG_ZEROCOPY`；载荷不可读时无法照搬普通复制回退 |

发送入口检查见 `net/ipv4/tcp.c:1102`。正式语义见 `Documentation/networking/msg_zerocopy.rst:23`、`Documentation/networking/msg_zerocopy.rst:211`：约 10 KB 以上写入才通常有收益，这只是文档经验值；完成通知表示原缓冲区可复用，不是对端应用已读完。发生复制时完成甚至可早于真正发完。

接收 `tcp_mmap()` 位于 `net/ipv4/tcp.c:1839`，实际消费在 `tcp_zerocopy_receive()`（`net/ipv4/tcp.c:2169`）。`can_map_frag()` 检查完整页等条件并排除 compound/mapping 页（`net/ipv4/tcp.c:1879`）。`recv_skip_hint` 表示仍要通过复制消费的字节，不能跳过 TCP 字节流；`copybuf_address/copybuf_len` 可让小读直接走复制。

devmem 接收实现为 `tcp_recvmsg_dmabuf()`（`net/ipv4/tcp.c:2477`）。`MSG_SOCK_DEVMEM` 表明应用理解其语义；控制消息携带 offset、size、token，再用 `SO_DEVMEM_DONTNEED` 归还（`Documentation/networking/devmem.rst:146`）。要求见该文档第 79 行；第 382 行说明 loopback、软件 checksum、抓取 payload 等限制。因此不能拿普通 veth 环境宣称已验证 devmem。

## 4. 演进

| commit / 作者 | 动机 | 正文性能数据 |
|---|---|---|
| `f214f915e7db` / Willem de Bruijn | TCP 接入 `MSG_ZEROCOPY`，支持 TSO/GSO，本地回送复制避免无限等待。 | 两主机 10 路 TCP_STREAM，netserver cycles 最多降 70%，全系统最多降 20%，随包大小变化；不能当作通用提升。 |
| `05255b823a61` / Eric Dumazet | 修复早期 RX mmap 的锁顺序，拆成预留 VMA 与 getsockopt 两步。 | 旧 16 MB 映射需 32 KB 临时页指针数组，新实现消除它；该提交未提供吞吐性能数据。 |
| `8f0b3cc9a4c1` / Mina Almasry | devmem RX 通过控制消息与 token 交付不可直接读的载荷。 | 该提交未提供性能数据。 |
| `bd61848900bf` / Mina Almasry | devmem TX 复用发送 ZC 生命周期，禁用不可行的复制退路。 | 该提交未提供性能数据。 |

历史中的 devmem 函数名后来改变；本文以 6.18 实现为准。`git log -S 'TCP_ZEROCOPY_RECEIVE' -- net/ipv4/tcp.c` 可看后续变更。

## 5. 取舍

字节复制变少，页引用、TLB、通知、token 回收与应用状态机变复杂。小块数据中固定成本可能更大；丢包会延长原发送缓冲的占用；队列归属错误与遗漏归还会变成资源问题。io_uring ZC Rx 是另一套注册队列接口，本篇不展开其 ABI；不把它与 TCP 接收页映射混为同一实现。

## 6. 用户态对照

lwIP 2.2.0 的 `tcp_write()` 不设 `TCP_WRITE_FLAG_COPY` 时可引用应用数据，应用必须保持内容到 ACK；配置强制单个 pbuf 时会强制复制。这证明少一次系统调用并不消除可靠重传的所有权约束。[固定版本 tcp_out.c](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_2_0_RELEASE/src/core/tcp_out.c)

## 7. 验证

使用源码自带 `tools/testing/selftests/net/msg_zerocopy.c`、`tools/testing/selftests/net/tcp_mmap.c` 和 `tools/testing/selftests/drivers/net/hw/ncdevmem.c`，先阅读各自条件；按相同数据完整性、消息大小、CPU 和链路比较复制/ZC。至少同时记录 cycles/byte、吞吐、尾延迟和缓冲占用。此处未编译或运行这些测试；宿主 6.8 不能代表目标 6.18。

## 要点回顾

- “零拷贝”必须说清省的是哪一段。
- 完成通知、ACK、对端应用消费不是同一事件。
- ABI、硬件与内存布局决定能否兑现收益。

## 自测

1. ZC send 返回后能立刻改缓冲吗？
2. RX `recv_skip_hint` 允许丢字节吗？
3. devmem 为何不能任意退回软件 checksum？

<details><summary>答案</summary>

1. 不能，需等对应完成通知。2. 不允许，提示应复制消费多少字节。3. 内核可能无法访问载荷。

</details>

## 与 DPDK/VPP 的对照

把 mbuf 的所有权交给 TX 队列也有延迟回收，但 TCP 还可能为了重传保留内容。一次 TX completion 只结束那次设备使用，不能替代 TCP 对原数据的完整生命周期判定；即使用用户态栈，这个协议约束仍成立。
