# A1. sk_buff：把数据的存放方式和协议处理状态分开

源码基准：Linux 6.18，`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`。下列本地链接的行号对应此提交。函数、字段和调用关系已用 `rg`、源码阅读核对；历史用 `git log -S`、`git blame` 和 `git show` 核对。仓库不是浅克隆，历史止于 2005 年初始导入；这不等于包含 Linux 的全部早期历史。

## 1. 问题：为什么一个连续缓冲区不够

TCP 需要保留未确认的数据，以便重传；网卡发送又需要自己的包头和发送状态。若二者共享一个可随意修改的缓冲区，发送路径修改头部时就会破坏重传状态；若每次发送都完整复制，则把所有 payload 多搬一次。

另一个问题是数据来源不统一：普通 `send()` 的数据可以复制到内核页，文件和零拷贝数据原本就在页中，网卡接收的数据已经落在驱动准备的缓冲区。强制把所有来源拼成单个连续区域，会把每次接入协议栈都变成一次潜在复制。

Linux 因而把三个问题分开：**谁拥有协议处理状态，数据放在哪里，哪些字节允许修改。** `sk_buff` 主要回答第一个问题；head buffer、fragment 和引用计数回答后两个问题。TCP 保留 payload、发送 clone 的动机直接写在 [dataref 注释](../../../src/linux-6.18/include/linux/skbuff.h:632) 中。

这里的 fragment 指内存分段，不等于 IP 分片；一个 skb 也不保证对应一个线上包，GSO 可以让它代表多个待分段报文。

## 2. 约束：通用栈不能要求所有参与者采用同一分配器

- 同一个包可能穿过 TCP、IP、隧道、流量控制、驱动。各层追加头部、维护状态，但通常只需要读取 payload。
- TCP 保留数据的时间由 ACK 决定；设备发送完成、旁路观察者消费完 clone、应用释放用户页，是不同的生命周期。
- 驱动支持的 scatter-gather、校验和和分段能力不同。协议栈需要既能利用能力，也能在不支持时退回软件处理。
- softirq 等不能睡眠的上下文也会分配或扩展 skb，失败必须可以传播。`__alloc_skb()`、`skb_clone()` 的注释明确区分分配上下文，见 [skbuff.c:630](../../../src/linux-6.18/net/core/skbuff.c:630)、[skbuff.c:2015](../../../src/linux-6.18/net/core/skbuff.c:2015)。
- 内核接收不可信的长度、选项和封装。把包头当连续结构访问前，必须先保证字节已在线性区；共享数据在写入前必须证明独占或先复制。

后两点解释了为什么一个看似简单的“取 TCP 头指针”周围，经常出现长度检查、pull 和 COW 操作。

## 3. 方案：小范围连续、payload 可分散、共享时限定写权限

### 3.1 两个对象，以及三种数据所在的位置

`struct sk_buff` 本身不内嵌包数据。基本布局由 [include/linux/skbuff.h:735](../../../src/linux-6.18/include/linux/skbuff.h:735) 的内核文档直接描述：

```text
sk_buff 元数据
  head ──────┐
  data ───────────────┐
  tail/end 是指针或偏移，取决于配置
             ↓        ↓
head buffer: [headroom][线性数据][tailroom][skb_shared_info]
                                             ├─ frags[] → 数据页/其他 netmem
                                             └─ frag_list → 其他 skb
```

| 对象或字段 | 表示什么 | Linux 6.18 位置 |
|---|---|---|
| `sk_buff.head/data/tail/end` | 底层 head buffer、当前数据起点、已用末尾、线性容量末尾 | [skbuff.h:1092](../../../src/linux-6.18/include/linux/skbuff.h:1092) |
| `len`、`data_len` | 总数据长度、非线性数据长度；线性长度为 `len - data_len` | [skb_headlen():2531](../../../src/linux-6.18/include/linux/skbuff.h:2531) |
| `skb_shared_info.nr_frags/frags[]` | fragment 描述符数组及实际数量 | [skbuff.h:593](../../../src/linux-6.18/include/linux/skbuff.h:593) |
| `skb_frag_t.netmem/offset/len` | backing memory 引用、偏移、长度；6.18 的实际字段不是老资料里的裸 `struct page *` | [skbuff.h:361](../../../src/linux-6.18/include/linux/skbuff.h:361) |
| `skb_shared_info.frag_list` | 用其他 skb 表示的额外数据链 | [skbuff.h:602](../../../src/linux-6.18/include/linux/skbuff.h:602) |
| `gso_size/gso_segs/gso_type` | 描述分段工作，允许“大逻辑包”继续向下传递 | [skbuff.h:598](../../../src/linux-6.18/include/linux/skbuff.h:598) |
| `truesize` | socket 内存记账使用的成本；不能拿 `len` 替代 | [skbuff.h:1096](../../../src/linux-6.18/include/linux/skbuff.h:1096) |

`skb_shared_info` 放在 head buffer 的末端，由 [skb_shinfo():1783](../../../src/linux-6.18/include/linux/skbuff.h:1783) 定位；它不是 `sk_buff` 内嵌成员。普通页只是 `netmem` 的一种来源，设备内存带来的限制留到 A3。

这不是“所有包都非线性”。小包可以完全在线性区；头部和少量 payload 连续时，直接访问很便宜。需要多页、大包或复用已有数据时，再使用非线性部分。

### 3.2 TCP 的真实使用：保留 payload，发送时复制描述符

核对到的正常发送构造过程如下；这只是解释所有权变化，不展开整条发送调用链。

1. [tcp_stream_alloc_skb():907](../../../src/linux-6.18/net/ipv4/tcp.c:907) 用 `alloc_skb_fclone(MAX_TCP_HEADER, ...)` 准备 skb，并调用 `skb_reserve()` 留出头部空间。
2. [tcp_skb_entail():701](../../../src/linux-6.18/net/ipv4/tcp.c:701) 把 skb 放入 TCP 的发送管理范围，并用 `__skb_header_release()` 标记 payload-only 的所有权。
3. [tcp_sendmsg_locked():1244](../../../src/linux-6.18/net/ipv4/tcp.c:1244) 的普通拷贝分支将用户数据写入 page fragment，再合并或追加 `frags[]` 描述符。**普通 `send()` 也会使用非线性 skb，不必先启用零拷贝。**
4. [__tcp_transmit_skb():1466](../../../src/linux-6.18/net/ipv4/tcp_output.c:1466) 在 `clone_it` 分支生成发送副本：通常 `skb_clone()`，已有共享等条件下使用 `pskb_copy()`。原数据继续满足 TCP 保留/重传需求，向下发送的 skb 有独立元数据。

`skb_clone()` 的正常语义是分配或复用一个 metadata 对象，复制描述字段，再增加 `dataref`，不复制 payload；实现在 [__skb_clone():1541](../../../src/linux-6.18/net/core/skbuff.c:1541)。但它不是无条件零成本：入口会执行 `skb_orphan_frags()`，特殊的外部 buffer 所有权可能引出额外工作或失败，见 [skb_clone():2031](../../../src/linux-6.18/net/core/skbuff.c:2031)。

### 3.3 “共享 skb”和“共享数据”是不同的两件事

| 引用计数 | 保护的对象 | 直接后果 |
|---|---|---|
| `sk_buff.users` | 同一个 metadata 对象 | 多个持有者不能任意改同一份 skb 字段；`skb_shared()` 判断这一点 |
| `skb_shared_info.dataref` | 多个 skb 指向的同一份数据及 shared info | 每个 clone 的 metadata 独立，但 payload 不能任意改写 |
| `dataref` 高 16 位 | payload-only 持有者的数量 | 区分“保留 payload”与“需要改写头部”的持有者 |

低 16 位是总引用数，高 16 位是 payload-only 引用数。[skb_header_cloned():2068](../../../src/linux-6.18/include/linux/skbuff.h:2068) 检查二者相减之后是否只有一个可写头部持有者。

例如，原始 TCP skb 只保留 payload，另一个发送 clone 负责头部：总引用数为 2，payload-only 数为 1，可写头部持有者为 1。这样即使数据共享，发送 clone 仍可利用保留的 headroom 写头；再多一个需要头部的 clone，就不能继续假定头部独占。

这不是通用的任意多版本数据结构。[注释](../../../src/linux-6.18/include/linux/skbuff.h:653) 明确限制：不同 `hdr_len` 的多个 payload-only skb 不受支持，payload-only skb 不应该离开其所有者。性能来自调用者遵守这套约定，代价是约定复杂。

源码文档也需核对：[Documentation/networking/skbuff.rst:24](../../../src/linux-6.18/Documentation/networking/skbuff.rst:24) 写了 `skb_shared_info.refcount`，但 6.18 实际字段名是 `dataref`，不能照抄成不存在的成员。

### 3.4 预留 headroom：花空间换掉追加头部时的搬移

[skb_reserve():2925](../../../src/linux-6.18/include/linux/skbuff.h:2925) 只推进空 skb 的 `data` 和 `tail`，不新增分配、不移动 payload。后续各层可以在前方空隙构造自己的头部。

若预留不足或头部被共享，[skb_cow_head():3885](../../../src/linux-6.18/include/linux/skbuff.h:3885) 经 `__skb_cow()` 调用 `pskb_expand_head()`。后者重新分配 head buffer、复制线性部分，并维护 fragment 引用；这不是自动把所有 payload 线性化。扩展以后旧的头部指针可能失效，必须重取，见 [skbuff.c:2206](../../../src/linux-6.18/net/core/skbuff.c:2206)。

所以 `skb_cow_head()` 的设计意图是“只为将要修改的区域取得写权限”。它不保证线性区之外的 payload 可写。

### 3.5 把分配时机也与接收数据分开

[build_skb():481](../../../src/linux-6.18/net/core/skbuff.c:481) 可以把驱动已填入的数据缓冲区包装成 skb。它上方的 [注释](../../../src/linux-6.18/net/core/skbuff.c:443) 明确给出动机对应的使用顺序：先准备 RX ring 的数据区，DMA 完成后再构造 metadata，将仍然热的 metadata 交给协议栈。

这避免很早初始化 skb，等待网卡期间 metadata 又被逐出 CPU cache。`napi_build_skb()` 进一步使用 NAPI 的 metadata cache，见 [skbuff.c:520](../../../src/linux-6.18/net/core/skbuff.c:520)。

不能把旧 commit 的 API 原样当作 6.18 用法：当前 `build_skb()` 对 backing buffer 的约定已经变化，slab 来源应使用 `slab_build_skb()`，见同处注释。

## 4. 演进：哪些是旧设计，哪些是后来优化

以下均读取了本地提交正文。性能数字只写正文实际给出的内容；操作数或批大小不冒充吞吐测试。

| commit、作者、日期 | 一句话动机及设计变化 | 提交正文中的性能证据 |
|---|---|---|
| `1da177e4c3f41524e886b7f1b8a0c1fc7321cac2`，Linus Torvalds，2005-04-16 | 初始 Git 导入已经含 `frags[]`、`dataref` 的 16+16 拆分和 `skb_reserve()`；不是这些设计的原始引入提交 | 没有该设计的性能数据；真正引入日期、作者和提交动机 **未确认** |
| `b2b5ce9d1ccf1c45f8ac68e5d901112ab76ba199`，Eric Dumazet，2011-11-14 | 引入 `build_skb()`，将 metadata 构造推迟到 RX completion，以免 RX ring 等待期间初始化过的 cache line 变冷 | 描述 cache 冷却原因；没有吞吐、CPU 或延迟测量值 |
| `d0bf4a9e92b9a93ffeeacbd7b6cb83e0ee3dc2ef`，Eric Dumazet，2014-09-29 | 整理 fclone 的布局并用结构体表达，隔离 TCP/XFRM 对布局细节的依赖，便于试验其他布局 | 未提供性能数据；不是 fclone 的最初引入 |
| `6ffe75eb53564953e75c051e1c28676e1e56f385`，Eric Dumazet，2014-12-03 | 利用 clone 引用状态决定可用性，减少 fast clone 的原子操作 | 正文明确可省 **2 次原子操作**；没有吞吐/延迟测量值 |
| `f450d539c05a14c103dd174718f81bb2fe65cb4b`，Alexander Lobakin，2021-02-13 | 引入 `napi_build_skb()` 等入口，重用 NAPI 缓存的 skb metadata，并批量分配 | 比较批大小 **8、16、32** 后选择 **16**，满时批量释放 **32**；没有给出提升百分比 |
| `9ec7ea1462084df695f34c5ac2d2d2250d9d6897`，Jakub Kicinski，2022-05-09 | 重写 payload-only skb 文档，解释原有 `dataref` 拆分约定 | 纯文档变更，无性能数据，不能称为引入 clone 机制 |

复查这些结论的命令：

```bash
git log --format='%H %an %s' -S 'SKB_DATAREF_SHIFT' -- include/linux/skbuff.h
git log --format='%H %an %s' -S 'build_skb' -- net/core/skbuff.c
git blame -L 634,658 -- include/linux/skbuff.h
git blame -L 2031,2056 -- net/core/skbuff.c
git show --format=fuller b2b5ce9d1ccf1c45f8ac68e5d901112ab76ba199
```

## 5. 取舍：省掉数据搬运，增加布局和所有权的复杂度

| 得到什么 | 付出什么 | 容易成为负担的场景 |
|---|---|---|
| TCP 重传与设备发送共享 payload | metadata 副本、引用计数、不同释放时机 | 很小的包、clone 跨 CPU 传递，原子操作和 cache line 迁移占比高 |
| 复用 page/netmem，支持 scatter-gather | 访问 payload 需要遍历分段；fragment 数有上限 | 软件必须扫描整个 payload；设备不支持所需布局 |
| 常见包头可直接访问 | 必须检查线性长度，必要时 pull、复制和重新取指针 | 多层隧道、异常长头部、频繁修改包内容 |
| 预留空间时追加头部只需调整指针 | 每包预留空间与对齐造成内部浪费 | 小包为主、封装很浅且内存紧张 |
| 广泛复用同一种包表示 | metadata 同时服务路由、时间戳、卸载、socket 等用途 | 只执行固定少数操作的专用数据面，许多字段无需使用 |

这里的负担是从代码操作推导的场景判断，不是本机基准结果。`cb[48]` 和大量 union 已经在复用 metadata 空间，见 [skbuff.h:885](../../../src/linux-6.18/include/linux/skbuff.h:885)；不能把每个用途都算成独立、永远同时存在的额外开销。

软件退路也有明确代码：访问头部前，[pskb_may_pull():2864](../../../src/linux-6.18/include/linux/skbuff.h:2864) 可将所需字节拉入线性区；发送设备不支持相关非线性形式时，[dev.c:4005](../../../src/linux-6.18/net/core/dev.c:4005) 会检查 `skb_needs_linearize()` 并线性化。**允许分散存储，不代表整条路径永远不复制。**

`truesize` 则把部分空间浪费转为可治理的成本。`SKB_TRUESIZE()` 至少计入 metadata 和 shared info，见 [skbuff.h:272](../../../src/linux-6.18/include/linux/skbuff.h:272)。若只按 payload 记账，小包就能以很少 TCP 字节消耗很多内存；这与 A2 的资源控制直接相关。

## 6. 对照：用户态也需要分段和共享，区别在适用范围

lwIP 2.2.0 的 `pbuf` 同样支持链、引用计数和预留头部。`PBUF_RAM` 可将 metadata 和数据一次分配；`PBUF_ROM/PBUF_REF` 引用外部数据；`PBUF_POOL` 适合接收并可形成链。这表明“简单栈必然连续且每次复制”并不成立。[官方 pbuf.h](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_2_0_RELEASE/src/include/lwip/pbuf.h)

lwIP 通过类型和应用约定区分可变数据：外部数据排队时可能必须复制，而不可变数据可以继续引用。其 `pbuf_alloc()` 对 `PBUF_REF` 的注释明确给出线程和排队约束。[官方 pbuf.c](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_2_0_RELEASE/src/core/pbuf.c)

DPDK 则在通常的直接 mbuf 中选择 metadata 与固定大小数据区一起分配，方便一次分配/释放；同时保留 headroom、链式 mbuf 和 indirect buffer 的共享引用。它和 skb 面对的是相似的存储问题；DPDK 本身不是 TCP 栈，这里只比较你熟悉的包容器。[官方 Mbuf Library](https://doc.dpdk.org/guides/prog_guide/mbuf_lib.html)

从这些接口可推导的取舍是：当应用、分配器、网卡和生命周期都由同一部署控制，可以选择固定池和更强的调用约定，少承担通用内核对任意应用组合的适配成本。若用户态栈也需要克隆、异步发送、可变封装和多来源零拷贝，所有权及 COW 问题仍会回来；只是由应用或库承担。

外部资料于本次编写实际访问。lwIP 引用固定发布 tag；DPDK 链接是在线文档，所见版本为 26.07.0，不用于推断 Linux 6.18 的实现。

## 7. 验证：观察何时走到了昂贵的布局修复路径

以下是待执行的观察方法，本任务没有运行压测，也没有测得性能增益。先在目标 6.18 内核确认符号可探测：

```bash
sudo bpftrace -l 'kprobe:*pskb_expand_head*'
sudo bpftrace -l 'kprobe:*skb_clone*'
sudo bpftrace -e '
kprobe:skb_clone { @clones = count(); }
kprobe:pskb_expand_head { @head_expand[comm] = count(); }
interval:s:10 { exit(); }'
```

用同一流量分别经过普通路径和需要额外封装的路径，比较每百万包的 `pskb_expand_head()` 次数，再用 `perf record -a -g` 看调用者。进程名可能是处理 softirq 的当前上下文，不能当成 socket 所属应用。

该计数能说明头部扩展/COW 分支出现的频率，不能单凭它计算复制字节数或 clone 的总成本。`skb_clone()` 也可能使用 fclone；真实成本需要结合调用栈、包大小和 CPU cycles。符号被内联、优化或禁止探测时，先调整观测入口，不把零事件当作功能不存在。探针和聚合语法参照 [bpftrace 官方文档](https://bpftrace.org/docs/release_024/language)。
