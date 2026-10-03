# A2. socket 内存：用记账额度协调吞吐、隔离与系统生存

源码基准：Linux 6.18，`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`。函数、字段、作用域和调用关系已经 `rg`、源码阅读核对；历史通过 `git log -S`、`git blame`、`git show` 核对。仓库不是浅克隆；2005 年初始导入以前的设计历史未包含在这份 Git 历史中。

## 1. 问题：谁为网络排队占用的内存买单

TCP 的队列不能只按“线上有多少字节”计费。发送方要保留尚未确认的数据，接收方要保留应用尚未读取的数据，还可能保留乱序数据。一个只有少量 payload 的 skb，也可能占据一个页片段、metadata 和对齐空间。

如果每条连接都只追求吞吐，一台机器上足够多的连接就能耗尽内存；如果每条连接都被固定在很小额度内，高带宽、高 RTT 路径又无法填满。因此需要同时解决三件事：单连接可扩张、总量可控制、资源紧张时仍能让连接向前推进。

这里所谓“预分配”首先是**内存使用的记账额度**。`sk_forward_alloc` 不是在 socket 创建时分配给它的一批独占物理页，也不是网卡 RX buffer pool。实际 skb/page 分配与额度检查分开执行；例如 [tcp_stream_alloc_skb():907](../../../src/linux-6.18/net/ipv4/tcp.c:907) 先尝试分配 skb，再决定是否获得记账许可。

## 2. 约束：额度不是一个统一的“每连接最大字节数”

- 不同应用的消息大小、读取速度、连接数和带宽时延积不同；内核只能动态估计合适的队列大小。
- 网络接收不能等待应用释放内存，softirq 也不能任意睡眠；发送系统调用则通常可以等待可写条件。
- 一个租户不能用很多小连接绕过总量约束；但另一个租户仍在自己的预算内时，不应被错误的全局平均值规则限制。
- 应用显式设置 socket buffer 是长期 ABI，数值的历史解释必须兼容。内核会将 `SO_RCVBUF/SO_SNDBUF` 的输入值加倍，容纳 metadata 等额外成本。
- 不能为了严格限额制造永久无进展：数据不能排队、ACK 不能推进、发送方又无法进入正常等待路径时，需要有针对性的例外。

这些约束在 [__sk_mem_raise_allocated() 的公平性/DoS 注释](../../../src/linux-6.18/net/core/sock.c:3283)、[SO_RCVBUF 兼容注释](../../../src/linux-6.18/net/core/sock.c:982) 和 [发送侧限额例外](../../../src/linux-6.18/net/core/sock.c:3328) 中有直接证据。

## 3. 方案：分层限额，按页批量记账，压力下逐级退让

### 3.1 先分清六个常见字段

字段集中定义于 [struct sock](../../../src/linux-6.18/include/net/sock.h:414)。以下单位均为字节，另有说明的全局协议量除外。

| 字段 | 回答的问题 | 不等于什么 |
|---|---|---|
| `sk_rcvbuf` | 这条 socket 当前允许的接收缓冲规模是多少 | 不等于当前分配量，也不等于通告给对端的 TCP window |
| `sk_sndbuf` | TCP 的发送缓冲规模目标/限制是多少 | 不等于网卡 ring 容量或拥塞窗口 |
| `sk_rmem_alloc` | 接收侧已经归属此 socket 的 skb 记账成本是多少 | 不等于应用可读 payload 字节数 |
| `sk_wmem_queued` | TCP 持久发送队列，包括未发送和待确认数据的记账成本是多少 | 不等于设备当前还没发完的字节数 |
| `sk_wmem_alloc` | 已交向下层、仍关联 socket 的发送 skb 的成本/生命周期引用是多少 | 不等于 `sk_wmem_queued`；底层存储可能重叠，不能直接相加当物理内存 |
| `sk_forward_alloc` | 已计入协议/memcg，但尚未被具体队列使用的额度还有多少 | 不等于实际分配好的空闲 page 列表 |

`sk_wmem_alloc` 还带初始引用偏置 1；[sk_wmem_alloc_get():2312](../../../src/linux-6.18/include/net/sock.h:2312) 返回值会减掉它。TCP 发送 clone 在 [tcp_output.c:1536](../../../src/linux-6.18/net/ipv4/tcp_output.c:1536) 增加该引用，而 TCP 持久队列在 [tcp_skb_entail():701](../../../src/linux-6.18/net/ipv4/tcp.c:701) 增加 `sk_wmem_queued` 并扣减 forward credit。两者描述不同生命周期。

`skb_set_owner_r()` 则把 `skb->truesize` 加到接收记账，再调用 `sk_mem_charge()`，见 [sock.h:2415](../../../src/linux-6.18/include/net/sock.h:2415)。A1 中非线性布局、metadata 和分配颗粒度，就是不能只按 payload 计费的原因。

`truesize` 是网络资源控制的计费值，不是整个机器物理内存使用量的精确分摊。尤其纯 `MSG_ZEROCOPY` 数据还有用户页锁定和不同的记账分支，见 [A3](A3-zero-copy.md)。不能从 `tcp_mem` 统计反推所有被网络引用的用户页总量。

### 3.2 forward allocation：先批量取得额度，再在 socket 内消费

[sk_wmem_schedule()/__sk_rmem_schedule()](../../../src/linux-6.18/include/net/sock.h:1544) 先比较请求量与 `sk_forward_alloc`。够用时不重新申请；不够时，`__sk_mem_schedule()` 将缺口向上取整到页，尝试增加协议和 memcg 的记账，失败就回滚，见 [sock.c:3365](../../../src/linux-6.18/net/core/sock.c:3365)。

可以把它看成一个小额备用金账户：

```text
取得 1 页额度 → 协议/memcg 记账增加，sk_forward_alloc 增加
队列使用 N 字节 → sk_mem_charge() 从 sk_forward_alloc 扣 N
队列释放 N 字节 → sk_mem_uncharge() 归还 N
可退额度达到整页 → sk_mem_reclaim() 将整页退还协议/memcg
```

若页大小为 4096，当前额度 0，某次需要计费 2000 字节，则可以取得 4096 字节额度，消费后余 2096 字节。这里的数字是说明记账算法，不表示真正分配了一个供 socket 独占的 4096 字节数据页。

实际扣还逻辑在 [sock.h:1586](../../../src/linux-6.18/include/net/sock.h:1586)、[sock.h:1605](../../../src/linux-6.18/include/net/sock.h:1605)。6.18 对普通 socket 尽快退回整页闲置额度；没有使用 `SO_RESERVE_MEM` 时，不能照搬旧文章里“每 socket 长期囤几 MB forward allocation”的描述。

第二层摊销发生在 CPU 上：[proto_memory.h:53](../../../src/linux-6.18/include/net/proto_memory.h:53) 将协议总量增减先累计在 per-CPU 计数器，超过阈值才冲刷到全局原子计数器。`net.core.mem_pcpu_rsv` 以页为单位，默认对应每 CPU 1 MiB，见 [sysctl 文档](../../../src/linux-6.18/Documentation/admin-guide/sysctl/net.rst:210)。

这样既能缩小每 socket 囤积的额度，又不必每次回收都修改所有 CPU 争用的全局 cache line。代价是全局读数包含尚未冲刷的误差，不能解释成瞬时精确的内存总账。

### 3.3 “每 socket 的额度”至少有三种含义

| 机制 | 含义 | 是否预先给 socket 分配实际数据页 |
|---|---|---|
| `tcp_rmem/tcp_wmem` 的 min/default/max | 最小用量的压力规则、初始 buffer 值、自动调节上限 | 否 |
| `sk_forward_alloc` | 按需取得、待消费或回收的记账额度 | 否 |
| `SO_RESERVE_MEM` / `sk_reserved_mem` | 应用显式预记账，保留一部分平时不退还的额度 | 仍然不是分配 skb/page 的操作 |

TCP 创建时从所在 netns 的 `tcp_wmem[1]/tcp_rmem[1]` 初始化 buffer 值，见 [tcp.c:491](../../../src/linux-6.18/net/ipv4/tcp.c:491)。接收自动调节根据应用消费和 RTT 估计需求；`tcp_rcv_space_adjust()` 调用 `tcp_rcvbuf_grow()`，后者受 `tcp_rmem[2]` 和应用是否锁定 buffer 控制，见 [tcp_input.c:897](../../../src/linux-6.18/net/ipv4/tcp_input.c:897)、[tcp_input.c:933](../../../src/linux-6.18/net/ipv4/tcp_input.c:933)。

应用设置 `SO_RCVBUF` 会锁定接收 buffer 的自动调节；`SO_SNDBUF` 类似地锁定发送 buffer。内核保存约两倍输入值的历史行为，见 [sock.c:980](../../../src/linux-6.18/net/core/sock.c:980)、[sock.c:1338](../../../src/linux-6.18/net/core/sock.c:1338)。因此比较 sysctl、应用参数和 `ss` 输出时，必须分清是哪一层的数值。

`SO_RESERVE_MEM` 实现在 [sock_reserve_memory():1029](../../../src/linux-6.18/net/core/sock.c:1029)：要求启用 socket memcg 记账，先 charge memcg 和协议量，若预记账已使协议量超过 pressure 阈值就回滚；成功后增加 `sk_reserved_mem`。后续普通 reclaim 保留未使用的 reservation。它是在公平性边界内，用长期占用预算换更少 charge/reclaim 操作。

### 3.4 全局、netns 和 memcg：三个作用域不能混淆

| 控制/统计 | 6.18 实际作用域及证据 | 工程含义 |
|---|---|---|
| `tcp_mem[3]`、TCP `memory_allocated`、`tcp_memory_pressure` | 宿主共享；[tcp.c:305](../../../src/linux-6.18/net/ipv4/tcp.c:305) 的全局变量及 [tcp_prot:3518](../../../src/linux-6.18/net/ipv4/tcp_ipv4.c:3518) 绑定 | 不是每个 netns 自带一套 TCP 总预算 |
| IPv4 TCP 与 IPv6 TCP | 指向同一个总计数和阈值，见 [tcpv6_prot:2370](../../../src/linux-6.18/net/ipv6/tcp_ipv6.c:2370) | IPv4 与 IPv6 不拥有两份独立的内存池 |
| `net.ipv4.tcp_mem` 的注册 | 放在初始 netns 的全局表，见 [sysctl_net_ipv4.c:557](../../../src/linux-6.18/net/ipv4/sysctl_net_ipv4.c:557)、[注册处:1686](../../../src/linux-6.18/net/ipv4/sysctl_net_ipv4.c:1686) | 不应把修改另一个 netns 内的同名路径当作建立独立预算 |
| `tcp_rmem/tcp_wmem` | socket 所在 netns 的配置，见 [tcp.c:491](../../../src/linux-6.18/net/ipv4/tcp.c:491) | 可以分别设定各 netns 的默认值与自动调节边界，但这还不是总量隔离 |
| `sk_memcg`、memcg socket charge | socket 关联的 memory cgroup；[memcontrol.c:4997](../../../src/linux-6.18/mm/memcontrol.c:4997)、[memcontrol.c:5053](../../../src/linux-6.18/mm/memcontrol.c:5053) | cgroup v2 会纳入该组的内存记账；与全局 TCP 限额并行生效 |

memcg 是额外的资源边界，不替换全局 TCP 账本。cgroup v1 与 v2 的实现分支也不同，不能把旧的 `memory.kmem.tcp.*` 专用接口直接当作 v2 的控制方式。v2 路径调用 `try_charge_memcg()`，并更新 `MEMCG_SOCK`，见 [memcontrol.c:5053](../../../src/linux-6.18/mm/memcontrol.c:5053)。

`tcp_under_memory_pressure()` 会检查 socket 的 memcg 压力或全局 TCP 压力，见 [tcp.h:300](../../../src/linux-6.18/include/net/tcp.h:300)。但“是否进入压力模式”和“某次申请能否获准”仍是两层决策。

### 3.5 tcp_mem：带滞回的策略阈值，不是精确隔离容器

[Documentation/networking/ip-sysctl.rst:639](../../../src/linux-6.18/Documentation/networking/ip-sysctl.rst:639) 定义三个数，单位为页：

- `min`：低于此值，退出全局 TCP 内存压力模式。
- `pressure`：高于此值，进入压力模式。
- `max`：总量过高时进入拒绝/特殊处理分支。

中间区间保留原压力状态，避免每次增减一个包都来回切换。代码顺序见 [__sk_mem_raise_allocated():3253](../../../src/linux-6.18/net/core/sock.c:3253)。默认值从启动时可用 buffer pages 推导，见 [tcp_init_mem():5088](../../../src/linux-6.18/net/ipv4/tcp.c:5088)，不能把源码注释中的比例直接解释成任意机器当前物理 RAM 的精确比例。

压力下仍允许低于 `tcp_rmem[0]/tcp_wmem[0]` 的连接获得最低用量，也会对低于平均用量的 socket 给予机会。**最低额度不是可绕过总量上限的无条件保证**：代码先处理全局 max 和 memcg charge 失败，再处理最低用量，否则创建海量低用量 socket 就能构成 DoS，见 [sock.c:3279](../../../src/linux-6.18/net/core/sock.c:3279)。

代码所谓“平均”是拿 `tcp_mem[max]` 与“socket 总数 × 该 socket 的页用量”比较，相当于判断是否低于按连接数均摊的总预算；不是测量所有活跃连接的当前平均值。这个启发式只针对全局压力。仅有某个 memcg 处于压力时，不能拿全宿主的均摊额度限制该组仍获准使用的预算，见 [sock.c:3306](../../../src/linux-6.18/net/core/sock.c:3306)。

`max` 也不是绝不越过一字节的实时阀门：per-CPU 记账会延迟汇总；并发申请需要回滚；stream 发送在特定条件下会让申请通过，以便后续能按 sndbuf 规则等待，甚至在 memcg charge 上使用 `__GFP_NOFAIL`，见 [sock.c:3328](../../../src/linux-6.18/net/core/sock.c:3328)。此外该协议量主要服务队列记账，并不涵盖网络子系统的全部内存。

### 3.6 压力到来以后：降低增长、整理队列，最后才丢弃

发送侧 [tcp_should_expand_sndbuf():5809](../../../src/linux-6.18/net/ipv4/tcp_input.c:5809) 在压力下抑制 buffer 扩张；申请被压制时可调用 `sk_stream_moderate_sndbuf()`，见 [sock.c:3331](../../../src/linux-6.18/net/core/sock.c:3331)。这不是“发现压力后立刻关闭所有连接”。

接收侧 [tcp_try_rmem_schedule():5115](../../../src/linux-6.18/net/ipv4/tcp_input.c:5115) 检查能否容纳 incoming skb、能否取得记账额度；失败时走 `tcp_prune_queue()`，必要时再删减乱序队列。

[tcp_prune_queue():5762](../../../src/linux-6.18/net/ipv4/tcp_input.c:5762) 的逐级退让是：调整接收窗口相关状态；检查是否已有空间；尝试合并/压缩乱序和接收队列以节省 skb 开销；仍不够就修剪乱序数据；最后让调用者丢弃新数据，等待 TCP 重传恢复。[tcp_collapse() 的复制操作](../../../src/linux-6.18/net/ipv4/tcp_input.c:5616) 说明这里先用 CPU 和复制换内存，再用重传换存活。

这还包含安全上的工作量控制：[tcp_prune_ofo_queue():5708](../../../src/linux-6.18/net/ipv4/tcp_input.c:5708) 以 `sk_rcvbuf / 8` 为一次释放目标，从高序号一端清理，并尽量保留比 incoming packet 更有用的较早数据。其目标是避免每收到一个恶意小包就重复扫描大树；因序号保护等停止条件，不能把“12.5% 目标”说成每次都无条件释放至少这么多。

最后一个兼容细节尤其体现通用性的代价：当前 [tcp_can_ingest():5108](../../../src/linux-6.18/net/ipv4/tcp_input.c:5108) 判断是 `sk_rmem_alloc + skb->len <= sk_rcvbuf`，而实际入账仍用 `truesize`。源码注释解释：老应用的小 `SO_RCVBUF` 配合 LRO/hardware GRO，可能让一个小 payload 占据完整页；如果新包准入也完全用 `truesize`，会丢弃对端依通告窗口合法发来的数据。内核选择放松准入，保留真实成本记账。

## 4. 演进：减少全局争用，也修正隔离与兼容问题

下表均来自实际读取的提交正文；没有给出基准结果时明确标注。原始 `sk_forward_alloc` 已在 2005 初始导入中，真正首次引入的动机和提交 **未确认**。

| commit、作者、日期 | 一句话动机及变化 | 提交正文中的数据 |
|---|---|---|
| `3ab224be6d69de912ee21302745ea45a99274dbc`，Hideo Aoki，2007-12-31 | 将 stream 的内存记账抽象为通用协议接口，TCP/SCTP 改用统一 `sk_mem_*`；不是记账概念的首次引入 | 未提供性能数据 |
| `e805605c721021879a1469bdae45c6f80bc985f4`，Johannes Weiner，2016-01-14 | 分开检查 memcg 用量/限额与全局用量/限额，修复原模型可绕过全局限制的问题 | 未提供性能数据 |
| `72cd43ba64fc172a443410ce01645895850844c8`，Eric Dumazet，2018-07-23 | 乱序队列按批清理，避免恶意 tiny packets 反复触发昂贵扫描 | 提到旧默认 **6 MB** 队列可有约 **7000** 个包，改用容量约 **12.5%** 的清理目标；不是吞吐实测 |
| `2bb2f5fb21b0486ff69b7b4a1fe03a760527d133`，Wei Wang，2021-09-29 | 加入 `SO_RESERVE_MEM`，在 memcg 约束内预记账，用保留预算换更少 forward alloc/reclaim | 未提供性能数据；正文预期减少 cycles，没有测量值 |
| `3cd3399dd7a84ada85cb839989cdf7310e302c7d`，Eric Dumazet，2022-06-08 | 通过 per-CPU 额度累计减少共享 `memory_allocated` 的 cache line 争用 | 明确采用每 CPU **±1 MB** 缓存；没有吞吐/延迟数据 |
| `4890b686f4088c90432149bd6de567e621266fa2`，Eric Dumazet，2022-06-08 | 尽快回收每 socket 未使用的 forward allocation，以新 per-CPU 缓存抵消全局更新成本 | 正文举例：旧实现每 socket 可囤 **2 MB**，**10000** 个可留 **20 GB**；这是规模估算，不是物理页驻留实测 |
| `66e6369e312d161708786123fb44ecd53ff32d82`，Abel Wu，2023-10-19 | 将“低于平均用量可增长”的规则限制在全局压力，撤销其对仅 memcg 压力的错误使用 | 未提供性能数据 |
| `1d2fbaad7cd8cc96899179f9898ad2787a15f0a0`，Eric Dumazet，2025-07-11 | 准入检查纳入新包大小，避免仅检查旧队列导致 BIG TCP 大包严重超额 | 举 **1/2 MB** BIG TCP 包说明超额规模；未给出基准 |
| `f017c1f768b670bced4464476655b27dfb937e67`，Eric Dumazet，2025-09-27 | 在上述严格化之后改用 incoming `skb->len`，兼容小 SO_RCVBUF 与硬件聚合的组合 | 举 **4 KB** 页容纳不足 **1500 B** payload 的现象；未给出吞吐/丢包率测量 |

另核对了 `2e12072c67b5f65fc71a569985a1262531fbdc06`（Abel Wu，2023-10-19）：这是解释最低保证、DoS 与平均规则作用域的注释提交，不应当成机制首次引入。正文无性能数据。

复查入口：

```bash
git log --format='%H %an %s' -S 'sk_forward_alloc' -- include/net/sock.h
git log --format='%H %an %s' -S 'per_cpu_fw_alloc' -- include/net/sock.h
git log --format='%H %an %s' -S 'sk_reserved_mem' -- include/net/sock.h
git blame -L 3279,3325 -- net/core/sock.c
git blame -L 5094,5113 -- net/ipv4/tcp_input.c
git show --format=fuller 4890b686f4088c90432149bd6de567e621266fa2
```

## 5. 取舍：公平性是带成本和边界的策略

| 得到什么 | 付出什么 | 哪类负载容易感到负担 |
|---|---|---|
| 自动扩大窗口，适应不同 BDP | 估计滞后、增长/回收判断，规模大时要防囤积 | 海量连接与高 BDP 大流并存 |
| 单连接、协议总量、memcg 多层治理 | 多次记账、不同单位和作用域，排障不直观 | 很小的消息、高连接数、多租户 |
| per-CPU 累计减少全局争用 | 读数和阈值反应存在误差/延迟 | CPU 很多但配置的总预算很小 |
| 最低用量与有条件例外维护进展 | 限额不是任何时刻都精确不可突破 | 需要严格且简单的资源证明的专用系统 |
| collapse/prune 维持系统可用 | CPU 时间、payload 复制、丢包及重传，尾延迟增加 | 慢读应用、严重乱序、恶意小包 |
| 兼容旧 SO_RCVBUF 行为 | 更复杂的准入规则，允许某些计费超额 | 小 buffer 与现代硬件 GRO 混用 |

以上负载判断是从已核对机制推导，未做本机对比测量。不能把 TCP 压力模式等同于机器已经 OOM，也不能把 `tcp_mem` 看作 memcg 的替代品。

对网络安全工作更有用的问题是：**攻击者控制的是字节数、对象数、连接数，还是每个包触发的 CPU 工作量？** `truesize` 约束前两者的差异，协议/memcg 约束聚合用量，批量 prune 约束反复回收成本。只把 buffer 调大，可能同时扩大攻击者能制造的状态与单次处理延迟。

## 6. 对照：lwIP 用更直接的上限，部署者承担容量规划

lwIP 2.2.0 提供 `TCP_SND_BUF`（字节）、`TCP_SND_QUEUELEN`（pbuf 数）、`MEMP_NUM_TCP_PCB`（连接对象数）、`MEMP_NUM_TCP_SEG`（排队 segment 数）等配置；乱序队列也可配置字节或 pbuf 上限。这保留了“数据量和对象量分别控制”的原则。[官方 opt.h](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_2_0_RELEASE/src/include/lwip/opt.h)

实际发送检查同时查看 `pcb->snd_buf` 和 `pcb->snd_queuelen`，超限返回 `ERR_MEM`。因此用户态栈并没有消除背压，只是可以把处理背压的契约交给应用。[官方 tcp_out.c](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_2_0_RELEASE/src/core/tcp_out.c)

池耗尽时，lwIP 的 `pbuf_free_ooseq()` 也会释放某个连接的乱序队列，优先让新包进入。[官方 pbuf.c](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_2_0_RELEASE/src/core/pbuf.c)

据此可以作出的设计比较是：单个受控固件或专用应用可以预先选择连接和缓冲上限，接受资源耗尽时更直接的失败，把跨租户公平性留给部署边界；Linux 则要在同一个宿主内持续协调相互不信任、行为各异的应用。这里没有声称 lwIP 的池不可配置，也没有声称所有用户态栈都采用静态池。外部源码为本次实际访问的固定发布 tag。

## 7. 验证：把协议总量、socket 和 cgroup 三份账并排看

以下实验方法未执行，不含测得结果。先记录目标内核、页大小、现有配置以及固定测试连接的状态：

```bash
uname -r
getconf PAGESIZE
sysctl net.ipv4.tcp_mem net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.mem_pcpu_rsv
cat /proc/net/sockstat
ss -tinm
nstat -az | rg 'TcpExt(TCPMemoryPressures|TCPMemoryPressuresChrono|PruneCalled|RcvPruned|OfoPruned|TCPRcvCollapsed)'
```

`/proc/net/sockstat` 的 TCP `mem` 使用协议总量，单位是页，见 [proc.c:64](../../../src/linux-6.18/net/ipv4/proc.c:64)。`ss -m` 展示的各个 socket 项对应 [sk_get_meminfo():3951](../../../src/linux-6.18/net/core/sock.c:3951) 中的字段；不能把它们全部相加。cgroup v2 环境再读目标组的 `memory.current`、`memory.stat` 中 `sock` 项、`memory.events`，其范围与 TCP 总量不同，字段定义见 [cgroup-v2.rst:1571](../../../src/linux-6.18/Documentation/admin-guide/cgroup-v2.rst:1571)。

`TCPMemoryPressures` 等名称已经在 [proc.c:233](../../../src/linux-6.18/net/ipv4/proc.c:233) 核对。压力标志虽然是全局的，相关计数更新却使用触发事件的 `sock_net(sk)`，见 [tcp_enter_memory_pressure():340](../../../src/linux-6.18/net/ipv4/tcp.c:340)；不能要求每个 netns 的计数都同步增长。

用同一个现成收发工具比较“接收方持续读取”和“接收方限速/暂停读取”，记录吞吐、RTT、buffer 与 prune/collapse 计数的差值。若需要触发全局 `tcp_mem` 压力，应在独立测试 VM 做配置对照；创建 netns 本身不会给全局 TCP 内存建立隔离。

还可以观察申请被压制的 tracepoint：

```bash
sudo bpftrace -lv 'tracepoint:sock:sock_exceed_buf_limit'
sudo bpftrace -e '
tracepoint:sock:sock_exceed_buf_limit
{ @denied[str(args.name), args.kind] = count(); }
interval:s:10 { exit(); }'
```

字段已在 [include/trace/events/sock.h:93](../../../src/linux-6.18/include/trace/events/sock.h:93) 核对；参数访问语法参照 [bpftrace 0.24 文档](https://bpftrace.org/docs/release_024/language)。`kind=0` 为发送，`kind=1` 为接收。它表示这条申请路径返回失败，不覆盖所有丢包，也不等于“全局 max 被突破”的唯一原因。结合 `perf record -a -g` 中的 `tcp_collapse()`/`tcp_prune_ofo_queue()` 调用栈，可观察内存问题是否正在转化成 CPU 与尾延迟问题。
