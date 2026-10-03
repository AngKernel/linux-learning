# B3 多核扩展：把包、连接与应用放到合适的 CPU

基线：Linux 6.18，`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`。本文代码位置均在该版本通过搜索和上下文阅读确认。仓库不是浅克隆，历史可追溯到 Linux Git 初始提交，无需 `git fetch --unshallow`。外部对照资料实际访问于 2026-10-02。

## 1. 问题：多了 CPU，为什么连接数和吞吐不一定增加

有 32 个 CPU，不等于一条连接可以由 32 个 CPU 同时推进。TCP 序号、拥塞窗口、重传和接收队列是同一连接的共享状态；如果多个 CPU 争用这些状态，增加 CPU 可能只是增加锁等待和缓存行迁移。B1 讨论单个连接怎样互斥，本篇讨论怎样把**不同连接的工作分开**。

扩展性还有两处更早的瓶颈。一处是网卡 RX 队列：如果所有包都经由一个队列上的协议处理，即使用户线程分散在各个 CPU，前面仍然只有一个处理入口。另一处是监听 socket：数十万个新连接都访问同一个 listener，如果 SYN、握手 ACK、accept 都争同一把锁，多队列网卡也救不了建连速率。

因此需要同时解决两个问题：让工作分布到多个 CPU；让一个连接的协议处理与应用处理尽量使用相近的缓存。负载均匀和缓存局部性不是同一个目标。RPS 主要解决前者，RFS 进一步解决后者。[本地设计文档：`Documentation/networking/scaling.rst:173,311`](../../../src/linux-6.18/Documentation/networking/scaling.rst)

## 2. 约束：内核不能要求所有应用都采用固定 worker 模型

内核要同时容纳共享一个监听 fd 的线程、每线程一个 listener 的服务器、频繁迁移 CPU 的进程，以及只建立几个连接的桌面程序。不能为了某一种服务器，把所有应用都改成“连接从建立到关闭永远由一个固定线程访问”。

还有以下约束：

- **保序。** 同一 TCP 流若突然换处理 CPU，新 CPU 上的后续包可能越过旧 CPU 队列里尚未处理的包。TCP 能恢复网络乱序，但人为制造乱序会增加额外处理，严重时触发不必要的重传。
- **硬件差异。** 单队列 NIC、多队列 NIC、虚拟网卡的能力不同；硬件队列数量也经常少于 CPU 数。软件补足硬件能力必须付出一次调度或跨核传递的成本。
- **负载与 NUMA。** 同一缓存域内移动工作，和跨 NUMA 节点移动工作，代价不同。平均分配流的数量不保证平均分配字节数、pps 或应用计算量。
- **隔离。** 同端口多 listener 不能允许无关用户任意加入别人的服务。Linux 的 reuseport 分组检查地址、设备、地址族和 `sk_uid` 等条件；见 [`net/ipv4/inet_hashtables.c:754`](../../../src/linux-6.18/net/ipv4/inet_hashtables.c)。CPU steering 本身也不等于租户资源配额。
- **敌对输入。** 攻击流可以集中压某个 RX 队列、CPU 或监听地址。`scaling.rst:47` 特别指出，用于双向流对称 RSS 的某些 XOR/OR-XOR 变换会减少输入熵，可能被利用。面向安全设备时，“双向落同核”和“均匀散列”需要一起评估。

## 3. 方案：五种选择，作用对象不同

### 3.1 先区分硬件队列、协议处理 CPU、应用线程和 socket

| 机制 | 选择什么 | 依据什么 | 不直接解决什么 |
| --- | --- | --- | --- |
| RSS | 硬件 RX 队列 | NIC 对流字段的 hash 和 indirection table | 不知道将来哪个应用线程消费数据 |
| RPS | 后续协议处理的 CPU | 流 hash、该 RX 队列的 CPU map | 不跟踪应用所在 CPU |
| RFS | 尽量靠近应用的协议处理 CPU | 最近使用 socket 的 CPU 提示、旧 CPU 队列进度 | 不把应用线程绑核，也不保证马上迁移 |
| XPS | 硬件 TX 队列 | 发送 CPU 或已记录 RX 队列的映射 | 不把发送线程迁移到另一 CPU |
| `SO_REUSEPORT` | 接收新连接的 listener | 默认 hash、可选 CPU 偏好或 BPF 策略 | 不自行完成 NIC 队列配置和线程绑核 |

这些机制可以组合。例：RSS 把流放入 RX 队列 2，IRQ/NAPI 通常在 CPU 2 处理；reuseport 选到 worker 2 的 listener；worker 2 也绑在 CPU 2；XPS 选与它接近的 TX 队列。这里的局部性来自几项配置互相配合，不是设置任一选项之后自动获得。

RSS 的“选队列”在硬件完成，驱动负责配置和传递队列/hash 信息，不能为所有网卡指出一个通用的 RSS 收包选队列函数。软件读取 RX 队列标记的位置可见 [`net/core/dev.c:5000`](../../../src/linux-6.18/net/core/dev.c)；RSS 的机制和 IRQ affinity 在 [`Documentation/networking/scaling.rst:24,95`](../../../src/linux-6.18/Documentation/networking/scaling.rst) 中有说明。中断亲和性也不是对所有 NAPI 执行方式的永久 CPU 绑定承诺。

### 3.2 RPS：用额外一次排队，换取协议处理并行

[`get_rps_cpu()`，`net/core/dev.c:4988`](../../../src/linux-6.18/net/core/dev.c) 读取 RX 队列的 `rps_map`，取 `skb` 的流 hash，再从 `map->cpus[]` 中选目标 CPU。`struct rps_map` 的 `len`、`cpus[]` 在 [`include/net/rps.h:19`](../../../src/linux-6.18/include/net/rps.h)。同一流在映射稳定时选同一 CPU，而不是每个包轮流分配一个 CPU。

接收入口据此调用 [`enqueue_to_backlog()`，`net/core/dev.c:5246`](../../../src/linux-6.18/net/core/dev.c)，把 skb 加入目标 CPU 的 `softnet_data.input_pkt_queue`；选择与入队的实际调用见同文件 `6269`。这是 **per-CPU backlog**，不是 B1 的 per-socket backlog。

普通软中断模式下，远端工作由 IPI 触发；`napi_schedule_rps()` 在同文件 `5158`，`rps_trigger_softirq()` 在 `5128`。6.18 还存在 backlog thread 分支，因此不能把“RPS 永远每包发送一次 IPI”当成定义：调度可以合并，也可以走线程唤醒分支。

它的直接代价是入队锁、额外排队、跨 CPU 通知及缓存迁移。在 RSS 已经让每个忙碌 CPU 拥有合适 RX 队列时，再打开 RPS 可能只是多绕一圈；这是 [`scaling.rst:240`](../../../src/linux-6.18/Documentation/networking/scaling.rst) 明确给出的判断。

### 3.3 RFS：为什么要两张表，不能直接追着应用 CPU 跑

RFS 使用 RPS 的分发机制，但加入应用反馈。当前代码在 [`inet_send_prepare()`，`net/ipv4/af_inet.c:833`](../../../src/linux-6.18/net/ipv4/af_inet.c) 和同文件 `inet_recvmsg():875` 调用 `sock_rps_record_flow()`；普通接收系统调用会记录提示，`MSG_ERRQUEUE` 接收除外。这里记录的是应用访问 socket 的 CPU，不是每个包到达时的 CPU。

相关字段不是一张“准确登记全部连接”的所有权表，而是可覆盖、可碰撞的局部性提示：

| 字段 | 含义 | 代码 |
| --- | --- | --- |
| `sk->sk_rxhash` | 连接接收方向的 hash，关联应用访问和流表 | `include/net/sock.h:392`；`include/net/rps.h:117` |
| `rps_sock_flow_table.ents[]` | 希望使用的 CPU；条目还带 hash 的高位，减少错误匹配 | `include/net/rps.h:52` |
| `rps_dev_flow.cpu` | 该 RX 队列当前实际用于此 flow slot 的 CPU | `include/net/rps.h:31` |
| `rps_dev_flow.last_qtail` | 上次把此 slot 的包入队时，目标 CPU 的队尾进度 | `include/net/rps.h:34` |
| `softnet_data.input_queue_head` | 对端已经出队到哪里 | `net/core/dev.c:5060` |

假设应用从 CPU 2 移到 CPU 6：

1. 应用下一次收发时，将“期望 CPU”更新为 6。`rps_record_sock_flow()` 的注释明确说这只是 hint，抢占仍可能改变 CPU；见 [`include/net/rps.h:72`](../../../src/linux-6.18/include/net/rps.h)。
2. 新包到来时，`get_rps_cpu()` 看见期望为 6、当前为 2，但先比较 CPU 2 的 `input_queue_head` 与 `last_qtail`。
3. CPU 2 尚未取走此前为该 slot 排队的包时，仍往 CPU 2 入队；进度追上，或旧 CPU 无效/离线时，才切到 6。判断见 [`net/core/dev.c:5047`](../../../src/linux-6.18/net/core/dev.c)。

这解释了为什么 RFS 需要区分“想去哪”和“目前能安全去哪”。它避免的是这次软件迁移造成的额外乱序，不承诺消灭网络乱序，也不保证表碰撞和应用频繁迁移时仍有理想局部性。

Accelerated RFS 则把学习到的放置结果反馈给支持此能力的网卡，让后续包更早落到合适 RX 队列，减少跨核转交；需要 NIC、驱动和配置配合，见 [`scaling.rst:414`](../../../src/linux-6.18/Documentation/networking/scaling.rst)。

### 3.4 XPS：不只发送要靠近，完成回收也要靠近

[`netdev_pick_tx()`，`net/core/dev.c:4594`](../../../src/linux-6.18/net/core/dev.c) 先看 socket 缓存的 TX 队列；需要重新选择时，调用同文件 `get_xps_queue():4545`。当前顺序是先尝试 `XPS_RXQS`，再 `XPS_CPUS`，最后退回流 hash。映射查找本身使用 RCU。

RX 队列映射适合应用按 RX 队列组织工作的情况；CPU 映射适合 worker 绑核的情况。它们既减少多个 CPU 争同一 TX 队列，也让发送完成、skb 释放更可能接近先前分配和使用它的 CPU；后一动机来自 [`scaling.rst:470`](../../../src/linux-6.18/Documentation/networking/scaling.rst)。

选出的队列缓存在 `sk->sk_tx_queue_mapping`，访问位置见 [`include/net/sock.h:1987`](../../../src/linux-6.18/include/net/sock.h)。否则线程 CPU 一变，下一包就可能走另一条拥塞程度不同的 TX 队列，人为造成乱序。

重新选择的门槛含 `skb->ooo_okay`。这里要以 6.18 代码为准：[`net/ipv4/tcp_output.c:1507`](../../../src/linux-6.18/net/ipv4/tcp_output.c) 判断的是“qdisc/device 队列没有本连接带 payload 的待发包”，**或**“重传队列已空”。`scaling.rst:527` 只用“此前数据都被 ACK”举例，不能据此写成唯一条件。

### 3.5 SO_REUSEPORT：让应用主动把监听入口分片

多个独立 listener 可以绑定同一服务地址/端口，每个有自己的 accept queue。它和多个线程共享同一个监听 fd 的区别在于：接收侧先选定一个 listener，应用不必在一个共享 accept queue 上竞争所有连接。

[`inet_lookup_reuseport()`，`net/ipv4/inet_hashtables.c:387`](../../../src/linux-6.18/net/ipv4/inet_hashtables.c) 根据四元组等上下文构造 hash，调用 [`reuseport_select_sock()`，`net/core/sock_reuseport.c:568`](../../../src/linux-6.18/net/core/sock_reuseport.c)。当前 reuseport group 保存 `socks[]`、`num_socks`、可选 `prog` 和 `incoming_cpu`；定义见 [`include/net/sock_reuseport.h:13`](../../../src/linux-6.18/include/net/sock_reuseport.h)。

- 普通情形从 `socks[]` 中按 hash 选成员，避免逐个比较组内所有 listener。
- 安装 reuseport BPF 程序后，程序可以影响选择；本篇只涉及选择位置，不展开 BPF API。
- 设置 `SO_INCOMING_CPU` 后，可优先选择与当前协议处理 CPU 匹配的 listener。当前代码有无匹配时的 fallback，因此这不是严格的 CPU 隔离规则；见 [`net/core/sock_reuseport.c:527`](../../../src/linux-6.18/net/core/sock_reuseport.c)。为了找匹配者，这种配置还可能重新引入组内线性扫描。

默认散列近似均匀分配新连接的数量，不感知 worker 此时忙不忙，也不保证每个连接工作量相同。一个 worker 阻塞时，它的 accept queue 可能积压，而另一个 worker 空闲。显式分片得到了局部性，同时把负载策略和 worker 健康管理的一部分责任交给应用。

### 3.6 listener 的“无锁”到底去掉了哪把锁

以前的核心组织方式是：握手中的 request 放在 listener 自己的 hash table；握手 ACK 必须先找 listener，再在 listener 下找 request。2015 年改造把 request 移进普通连接使用的 ehash，随后让 SYN 处理跳过 listener 的 socket 锁。

6.18 中，普通三次握手、未使用 syncookies/TFO 的简化时间线如下。这里区分“req 存放的位置”和“计数仍归哪个 listener”：

1. **SYN 建立半连接。** `tcp_conn_request()` 在 [`net/ipv4/tcp_input.c:7530`](../../../src/linux-6.18/net/ipv4/tcp_input.c) 调用 `inet_csk_reqsk_queue_hash_add()`。后者入口在 [`net/ipv4/inet_connection_sock.c:1190`](../../../src/linux-6.18/net/ipv4/inet_connection_sock.c:1190)，调用同文件 `1170` 的 `reqsk_queue_hash_req()`，由其通过 `inet_ehash_insert()` 插入 request，并设置该 request 自己的 `rsk_timer`。req 的 `rsk_listener` 仍指向所属 listener。
2. **握手 ACK 找 request。** [`tcp_v4_rcv()`，`net/ipv4/tcp_ipv4.c:2254`](../../../src/linux-6.18/net/ipv4/tcp_ipv4.c) 直接处理查到的 `TCP_NEW_SYN_RECV` 对象，经 `tcp_check_req()` 推进握手。这里的状态用于 request 这种小对象，不表示已经分配了完整的已连接 socket。
3. **完成握手，取得唯一 ownership。** 同文件 `1836` 通过 `inet_ehash_nolisten()` 用 child 替换旧 request；[`inet_ehash_insert()`，`net/ipv4/inet_hashtables.c:705`](../../../src/linux-6.18/net/ipv4/inet_hashtables.c) 仍持 ehash 对应的写锁。竞争赢家才完成后续入 accept queue，见 [`inet_csk_complete_hashdance()`，`net/ipv4/inet_connection_sock.c:1425`](../../../src/linux-6.18/net/ipv4/inet_connection_sock.c)。同一 request 被两个 CPU 同时处理时，不能各自产生一条成功连接。
4. **等待 accept。** request 通过 `req->sk` 指向完整 child，通过 `dl_next` 串入 accept queue。`rskq_accept_head/tail` 在 [`include/net/request_sock.h:185`](../../../src/linux-6.18/include/net/request_sock.h)。应用 `accept()` 从这里取 child；同结构中的 `qlen/young` 却是待处理 request 的计数，不要把它们与 accept queue 中已完成连接数混为一谈。

最直接的“无 listener socket 锁”证据只有几行，位于 `net/ipv4/tcp_ipv4.c:2363`：

```c
if (sk->sk_state == TCP_LISTEN) {
        ret = tcp_v4_do_rcv(sk, skb);
        goto put_and_return;
}
/* 普通连接稍后才执行 bh_lock_sock_nested(sk)。 */
```

这使多个 CPU 能并行处理同一个 listener 的 SYN，不必先排进其 socket backlog。但以下同步依然存在：

| 保留下来的同步 | 保护什么 | 6.18 证据 |
| --- | --- | --- |
| ehash 对应写锁 | request/child 发布、替换、同四元组冲突 | `net/ipv4/inet_hashtables.c:720` |
| `request_sock_queue.rskq_lock` | accept queue 头尾、child 入队/出队 | `net/ipv4/inet_connection_sock.c:1406`；`include/net/request_sock.h:215` |
| `accept()` 内的 `lock_sock(sk)` | 进程侧操作 listener 的串行化 | `net/ipv4/inet_connection_sock.c:671` |
| 原子 `qlen/young`、request 引用计数 | 跨 CPU 计数和 request 生命周期 | `include/net/request_sock.h:190,227`；`net/ipv4/inet_connection_sock.c:1186` |

所以“无锁 listener”指收包中的 listener socket 大锁被绕开，不是无原子操作、无共享缓存行，更不是所有与监听有关的操作都 wait-free。TFO 可提前创建 child，syncookies 不长期保存普通半连接 request；上面的时间线不能机械套用这两条分支，区别已体现在 `tcp_input.c:7510` 之后的代码中。

## 4. 演进：改的是瓶颈的位置，不是一次消灭所有同步

以下都用本地 `git log -S`、`git log -L` 或 `git blame` 定位，并用 `git show` 阅读了提交正文。性能数值是当年提交的实验，**本任务没有复现实测，也不能把它们当成 Linux 6.18 的性能保证**。

1. **RPS，2010，Tom Herbert。** `0a9627f2649a02bea165cfd529d7bcb625c2fcad`，`rps: Receive Packet Steering`。动机：每个设备队列里的协议处理串行化，让单队列 NIC 无法利用多核。正文测试为 500 个 netperf TCP_RR 实例、1 字节请求和响应：e1000e、8 核 Intel，从 **108K tps / 33% CPU** 到 **311K tps / 64% CPU**；forcedeth、16 核 AMD，从 **156K / 15%** 到 **404K / 49%**。这首先是利用更多 CPU 换吞吐，不是宣称每包 CPU 成本必定下降。正文还明确警告轻载退化、缓存拓扑和动态改 mask 的乱序风险。

2. **RFS，2010，Tom Herbert。** `fec5e652e58fa6017b2c9e06466cb2a6538de5b4`，`rfs: Receive Flow Steering`。动机：RPS 均匀分流后仍缺少应用局部性，而直接追踪应用 CPU 会制造乱序，因此引入 desired/current 两张表。正文 RPC 实验为每台主机 100 线程、结构类似 request/response 但用户态工作多于 netperf：RPS **174K tps、73% CPU、p99 2468 μs**，RFS **223K tps、73% CPU、p99 1382 μs**。正文也说简单 benchmark 有时退化，不能只保留收益数据。

3. **XPS，2010，Tom Herbert。** `1d24eb4815d1e0e8b451ecc546645f8ef1176d4f`，`xps: Transmit Packet Steering`。动机：按 CPU 选择 TX 队列，改善队列结构和发送完成的局部性。500 个 netperf TCP_RR 实例、1 字节请求/响应，bnx2x、16 核 AMD、16 TX 队列：无 XPS **996K tps**，每 CPU 一个 TX 队列时 **1234K tps**，两者均 **100% CPU**。

4. **TCP reuseport，2013，Tom Herbert。** `da5e36308d9f7151845018369148201a5d28b46d`，`soreuseport: TCP/IPv4 implementation`。动机：单 acceptor 转交连接会成瓶颈；多个线程共享 listener 时，唤醒不保证接收连接数公平。正文报告高建连负载下，最多与最少接收连接的线程可达 **3:1**，reuseport 的分布均匀；未给机器、吞吐、延迟数值。基础宏/选项由同系列 `055dc21a1d1d219608cd4baac7d0683fb2cbbe8a` 引入，不能把基础定义误当成完整 TCP 实现。

5. **拆开 accept queue 的锁，2015，Eric Dumazet。** `fff1f3001cc58b5064a0f1154a7ac09b76f29c44`，`tcp: add a spinlock to protect struct request_sock_queue`。动机：用专门的队列锁保护 child 入队，让软中断创建 child 不再受 listener 进程所有权/backlog 机制牵制。正文**未给性能数据**。这说明后来的“无锁”改造中，确实先增加了一把更小范围的锁。

6. **request 移入 ehash，2015，Eric Dumazet。** `079096f103faca2dd87342cca6f23d4b34da8871`，`tcp/dccp: install syn_recv requests into ehash table`。动机：握手 ACK 直接查到 request，不必先找并锁 listener；也为以后按 CPU/NUMA 选择 reuseport listener 提供条件，因为有状态握手后续包可直接找 request。正文称正常情况下 listener 锁压力减半，属于作者的结构性判断，**没有配套 benchmark 数值**。

7. **SYN 跳过 listener socket 锁，2015，Eric Dumazet。** `e994b2f0fb9229aeff5eea9541320bd7b2ca8714`，`tcp: do not lock listener to process SYN packets`。动机：此前的状态拆分已允许并行处理 SYN。正文写测试 **3.5 Mpps SYNFLOOD**，CPU 仍有余量；未给设备/CPU 型号和可直接比较的改造前吞吐。附 profile 中 listener 查找占 **13.18%**，并指出下一瓶颈是 listener 引用计数。

8. **修复 RFS 与无锁 listener 的衔接，2015，Eric Dumazet。** `6bcfd7f8c28887a4298bc4386b02cb90c9fa0c13`，`tcp: fix RFS vs lockless listeners`。动机：旧实现先更新 listener 的 `sk_rxhash`，child 通过克隆继承；不再修改 listener 后，必须正确设置 child 的 hash，否则首个数据包不能命中期望 CPU。正文**未给性能数据**。这是减少共享写入之后，需要显式迁移初始化职责的例子。

9. **普通 reuseport group 快速选择，2016，Craig Gallek。** `c125e80b88687b25b321795457309eaaee4bf270`，`soreuseport: fast reuseport TCP socket selection`。动机：把同接收地址的组成员放进数组，找到组内任意 listener 即可索引目标，不必扫描全部组成员；同时支持 BPF 选择。正文**未给性能数据**。

10. **减少 listener 引用计数竞争，2016，Eric Dumazet。** `3b24d854cb35383c30642116e5992fd619bdc9bc`，`tcp/dccp: do not touch listener sk_refcnt under synflood`。动机：对 listener 用 `SOCK_RCU_FREE` 管理回收，让查找不再每次写 `sk_refcnt`。正文在**非 SO_REUSEPORT listener 的 SYNFLOOD** 情形报告测试机从 **2.4 Mpps 到 3.2 Mpps，约 33%**，未给机器完整配置。不能和上一条 SYNFLOOD 数据拼成同一条连续曲线；B2 解释这与普通连接 slab 生命周期的区别。

11. **按地址和端口查 listener，2017，Martin KaFai Lau。** `61b7c691c7317529375f90f0a81a331990b1ec1b`，`inet: Add a 2nd listener hashtable (port+addr)`。动机：大量 IP 同时监听 443 时，只按端口散列会退化成长链，并容易被 SYN 攻击利用。引入 `lhash2`，正文**未给性能数据**。6.18 的地址/端口查找见 `net/ipv4/inet_hashtables.c:482`；不能把 2017 正文中的双表切换阈值当作现版本仍在用的规则。

12. **RX 队列驱动 XPS，2018，Amritha Nambiar。** `fc9bab24e9c654f62f3d411fc0b041be9e487e9d`，`net: Enable Tx queue selection based on Rx queues`。动机：允许按管理员的 RX→TX 映射选择队列，未匹配则回退 CPU map 和 hash。正文**未给性能数据**；busy-poll 工作负载的局部性理由见本地 `scaling.rst:482`，不要冒充该 commit 的测试结果。

13. **修复 CPU 偏好与快速选择的冲突，2022，Kuniyuki Iwashima。** `b261eda84ec136240a9ca753389853a3a1bccca2`，`soreuseport: Fix socket selection for SO_INCOMING_CPU`。动机：快速 reuseport 选择绕过了原有 CPU 匹配评分；有 CPU 偏好时重新扫描组，没偏好时保留 O(1) 选择。正文**未给吞吐/延迟数据**，明确指出这两种选择分别为 O(n)/O(1)。它是“支持通用配置会改变快路径复杂度”的直接证据。

可重做的定位命令，例如：

```bash
git log -S 'get_rps_cpu' -- net/core/dev.c
git log -S 'rps_sock_flow_table' -- net/core/dev.c
git log -S 'get_xps_queue' -- net/core/dev.c
git log -S 'sk_reuseport' -- net/ipv4/inet_hashtables.c
git log -S 'TCP_NEW_SYN_RECV' -- net/ipv4/tcp_ipv4.c
git log -S 'rskq_lock' -- include/net/request_sock.h
git blame -L 2363,2370 -- net/ipv4/tcp_ipv4.c
git log -L :reuseport_select_sock:net/core/sock_reuseport.c
git show --format=fuller 079096f103faca2dd87342cca6f23d4b34da8871
```

## 5. 取舍：扩展性提升之后，剩余限制在哪里

**分散工作不等于减少工作。** RPS 会增加一次转交；轻载时它可能增加延迟。RFS 会增加流表读写，而表越大越占缓存；如果 worker 频繁迁移或多线程轮流使用同一 socket，局部性提示会变化。更大的表解决碰撞，不解决不稳定的应用所有权。

**分片可以降低争用，但不能自动均衡重流。** RSS、RPS 和默认 reuseport 都基于流/连接做选择；一个持续占满 CPU 的连接仍可能成为热点。可选 RPS Flow Limit 在目标 CPU 的 backlog 压力下优先丢弃占比过大的流，照顾小流；见 [`scaling.rst:247`](../../../src/linux-6.18/Documentation/networking/scaling.rst)。这是一种粗粒度、按 hash 统计的拥塞保护，不是精确的每租户公平调度。

**更多队列不是永远更快。** 队列数增加可能增加总中断处理工作，缩小每次处理的批量；把 TX completion 放在远端 CPU 也可能抵消发送时的收益。文档在 [`scaling.rst:114`](../../../src/linux-6.18/Documentation/networking/scaling.rst) 区分了降低延迟和提高高包速率效率的队列选择目标。

**从大锁换成小锁、RCU 和原子变量，会增加生命周期推理成本。** 关闭 listener、定时器超时、两个 CPU 同时完成握手、reuseport 组变化都必须正确处理。收包中的大锁不再统一保护全部状态，代价从运行时争用转移到发布次序、引用和错误恢复逻辑；这一判断来自本节代码和上述修复历史，不是某个提交给出的定量结论。

**显式 listener 分片会暴露部署问题。** 6.18 提供 `tcp_migrate_req` 和 BPF 迁移策略，处理 listener 关闭时仍在握手或 accept queue 中的连接。默认不开启自动迁移；不同 listener 选项不一致时，迁移会破坏应用预期。见 [`Documentation/networking/ip-sysctl.rst:947`](../../../src/linux-6.18/Documentation/networking/ip-sysctl.rst)。这不能理解为已 accept 的任意连接都可自动迁移给另一个 worker。

## 6. 对照：用户态可以更早确定“谁拥有连接”

VPP 的典型多 worker 模式把 RX 队列分配给轮询 worker，RSS 将流分到队列，worker 按配置固定在 CPU 上。这样可以在部署阶段就确定主要处理者，减少 Linux 为任意线程迁移补偿的需求；但跨 worker 的流转和负载不均仍需要处理。[VPP 25.02 官方多线程说明](https://docs.fd.io/vpp/25.02/developer/corearchitecture/multi_thread.html)

VPP host stack 还通过 session layer 和共享内存基础设施对接应用。**VPP transport worker 和外部应用线程仍是两个执行主体**，不能从“worker 绑核”直接推出应用与 TCP 总在同一 CPU；前述“固定处理者更容易保持局部性”是架构对照推论。[VPP 25.02 官方 Host Stack 说明](https://docs.fd.io/vpp/25.02/aboutvpp/hoststack.html)

Seastar 的官方教程明确采用每核线程和分片状态，跨核用消息传递；连接建立后持续在同一 shard 处理。它能把应用和连接所有权一起设计，因此不必照搬 Linux 的“猜测最近哪个任意线程访问 socket”的机制。代价是应用服从分片、异步执行模型；重流热点和跨 shard 通信没有消失。Seastar 也支持内核网络栈，不能把所有 Seastar 部署都当成使用 native TCP 栈。[Seastar 官方教程 §1.2、§3.1、§18](https://docs.seastar.io/master/tutorial.html)

对有 VPP/DPDK 经验的读者，差异可以这样判断：用户态方案常先约束执行模型，再利用约束删掉热路径同步；Linux 保留更多线程与 fd 使用自由度，再通过 RFS、reuseport、专用锁和 RCU 找回一部分局部性。这个结论是从双方已列架构和源码归纳的设计取舍，不代表用户态栈没有隔离措施，也不代表内核不能配置成固定 worker 的运行方式。

## 7. 验证：分开观察队列、CPU、应用和建连能力

本节是可执行实验方案，**没有在当前主机修改配置或跑压测**。测试内核应核对版本和相关配置；先记录 NIC、队列数、NUMA 拓扑、IRQ affinity、irqbalance 状态、worker CPU、连接数、报文大小和 offload 状态。环回压测可观察 listener 行为，但不能证明物理 NIC 的 RSS/XPS 效果。

先读取放置关系，不先改参数：

```bash
ethtool -l eth0
ethtool -x eth0
ethtool -S eth0
cat /proc/interrupts
cat /proc/softirqs
cat /sys/class/net/eth0/queues/rx-0/rps_cpus
cat /sys/class/net/eth0/queues/rx-0/rps_flow_cnt
cat /sys/class/net/eth0/queues/tx-0/xps_cpus
cat /sys/class/net/eth0/queues/tx-0/xps_rxqs
sysctl net.core.rps_sock_flow_entries
```

将 `eth0` 和队列号换成实验网卡；`ethtool -S` 统计名称取决于驱动。查看测试环境全部相关队列，单独一项只能说明这一队列。RSS map、IRQ CPU、RPS CPU、应用 CPU 必须分开记录。

用运行内核实际可探测的符号观察协议处理与应用调用的 CPU 分布：

```bash
sudo bpftrace -l 'kprobe:tcp_v4_rcv'
sudo bpftrace -l 'kprobe:inet_recvmsg'
sudo bpftrace -l 'kprobe:inet_csk_accept'
sudo bpftrace -e '
kprobe:tcp_v4_rcv { @tcp_rx_cpu[cpu] = count(); }
kprobe:inet_recvmsg { @recv_cpu[comm, cpu] = count(); }
kprobe:inet_csk_accept { @accept_attempt_cpu[comm, cpu] = count(); }
interval:s:20 { exit(); }'
```

这是全系统 IPv4 TCP 接收入口、INET recv 调用和 accept **尝试**次数的分布，不是同一条连接的关联追踪，也不是成功 accept 计数；用独立实验机或隔离流量解释结果。符号可探测性依赖运行内核的配置和编译结果，未出现时不能声称它执行次数为零。

对同一工作负载分别做以下对照，每次只改一项，并恢复原值后再换下一组：

| 对照 | 希望验证的因果关系 | 同时需要看的代价 |
| --- | --- | --- |
| 少量 RX 队列：RPS 关/开 | TCP 接收处理能否分散到更多 CPU | 总 CPU、跨核开销、p99 延迟、丢包 |
| 固定 RSS/RPS：RFS 关/开，应用绑到已知 CPU | 应用处理与 TCP 处理是否更接近 | CPU 迁移、缓存 miss；不要只比较吞吐 |
| 相同 workers：共享 listener / 每 worker 一个 reuseport listener | 建连接收数量是否更均匀、共享队列争用是否下降 | 每 worker 完成连接数、accept queue 积压、错误/超时 |
| 固定 worker 和 RX：不同 XPS 映射 | TX 队列使用和完成处理局部性是否改变 | TX 队列统计、总 cycles、吞吐和尾延迟 |

把长连接吞吐与短连接建连实验分开。共享 listener 的限制主要出现在连接建立和 accept 阶段；只跑少数长连接不一定能看到 reuseport 收益。使用现有压测程序和支持切换上述 listener 模式的服务，不需要为理解这个设计另写协议栈。

```bash
sudo perf stat -a -e cycles,instructions,cache-misses,context-switches,cpu-migrations -- sleep 30
sudo perf record -a -g -- sleep 30
sudo perf report
```

这里测全系统，以免漏掉在别的 CPU/上下文执行的软中断工作。配合服务完成请求数计算每请求 cycles；通用 `cache-misses` 不能独自证明发生了跨 NUMA 迁移。若要检验 2015 年“去掉 listener socket 锁”的收益，需要受控的不同内核/补丁对照，6.18 没有一个 sysctl 能恢复那套旧实现。
