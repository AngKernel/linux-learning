# B1 socket 锁的双重模式：把不能等待的收包交给能够等待的拥有者

源码基准：Linux 6.18，`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`。本文中的行号对应这个版本。函数、字段和调用点已用 `rg` 核对；演进用本地 `git blame`、`git log -S`、`git show` 核对。仓库不是浅克隆，但标准 Git 历史从 2005 年开始，不包含更早的设计起源。

## 1. 问题：一个连接有两类执行者，谁可以修改它？

同一 TCP 连接可能同时面对应用线程的发送、接收、关闭，以及网卡收包触发的软中断。双方都会影响序列号、发送/接收队列和连接状态。多线程还可以共享一个 socket；应用线程与收包 CPU 也不一定相同。

只用一把普通自旋锁包住整个系统调用，会把可能睡眠的操作放进不能睡眠的临界区。只用可睡眠的互斥锁，软中断又不能等待它。完全不互斥则会让同一连接的状态机并发执行。

Linux 的解决方式是分开**短期物理互斥**与**长期逻辑拥有权**：用 `slock` 协调交接，用 `owned` 声明当前由进程上下文执行主协议逻辑。收包遇到拥有者时，把包挂到该 socket 的 backlog，由拥有者稍后处理。这个分工就在 [include/net/sock.h:79](../../../src/linux-6.18/include/net/sock.h#L79) 的注释中。

这里的 backlog 是**已查找到具体 socket 后的暂存包队列**，不是监听 socket 的 SYN 队列、accept 队列，也不是每 CPU 的网络输入 backlog。

## 2. 约束：内核不能要求所有应用遵守一个事件循环

- 应用可以使用阻塞 I/O、共享文件描述符、被抢占或迁移 CPU。内核不能要求连接永远由同一用户线程处理。
- 收包路径必须能在软中断上下文前进，不能因为某个应用暂时得不到调度而睡眠等待它。
- 用户内存访问可能发生缺页；持有逻辑 socket 锁与持有自旋锁必须区别对待。
- 队列必须受内存约束。不然一个慢接收者或恶意发送者能把“稍后处理”变成系统 OOM。
- 公平性不只涉及这个连接：长时间关 BH 会延迟其他连接收包；过于频繁地让出 CPU，又会拖长当前连接的反馈时间。

这些不是额外加在 TCP 上的抽象要求。2010 年 backlog 限制的提交记录了非特权本地发送者可触发的 OOM；2016 年、2025 年的改动分别处理后两种相反的调度代价，见第 4 节。

## 3. 方案：短自旋锁、可睡眠拥有权、暂存队列

### 字段分别保护什么

| 结构/字段 | 含义 | 源码 |
| --- | --- | --- |
| `socket_lock_t.slock` | 保护拥有权交接与 backlog 链接；收包直接执行 TCP 时也持有它 | [include/net/sock.h:83](../../../src/linux-6.18/include/net/sock.h#L83) |
| `socket_lock_t.owned` | 进程上下文是否拥有主协议状态；不是线程 ID，也不是一直持有的自旋锁 | 同上 |
| `socket_lock_t.wq` | 其他争用 socket 的进程睡眠等待的位置 | 同上 |
| `sock.sk_lock` | 每个 socket 自己的一套锁状态 | [include/net/sock.h:461](../../../src/linux-6.18/include/net/sock.h#L461) |
| `sock.sk_backlog.head/tail/len` | 暂存包链与本轮记账量；`len` 按内存占用计，不是包数 | [include/net/sock.h:400](../../../src/linux-6.18/include/net/sock.h#L400) |
| `sock.sk_rmem_alloc` | 已记到账户上的接收内存；与 backlog 合并检查 | [include/net/sock.h:1121](../../../src/linux-6.18/include/net/sock.h#L1121) |
| `sock.sk_backlog_rcv` | 拥有者处理暂存包时调用的协议回调 | [include/net/sock.h:1153](../../../src/linux-6.18/include/net/sock.h#L1153) |

`rmem_alloc` 恰好放在 `sk_backlog` 这个匿名结构中，只是填补布局空洞；源码注释明确说它在逻辑上不属于 backlog。

### 取得拥有权：自旋锁在函数返回前已经释放

`lock_sock()` 调用 `lock_sock_nested()`。后者的核心是：

```c
spin_lock_bh(&sk->sk_lock.slock);
if (sock_owned_by_user_nocheck(sk))
        __lock_sock(sk);
sk->sk_lock.owned = 1;
spin_unlock_bh(&sk->sk_lock.slock);
```

代码：[net/core/sock.c:3717](../../../src/linux-6.18/net/core/sock.c#L3717)，包装入口：[include/net/sock.h:1677](../../../src/linux-6.18/include/net/sock.h#L1677)。`_bh` 同时约束本 CPU 的 bottom-half 执行；自旋锁还协调其他 CPU。上面的“短期”是相对于整个系统调用而言，不是保证任何收包临界区都只有固定的几条指令。

若已有拥有者，`__lock_sock()` 把当前进程加入等待队列，释放 `slock` 后调用 `schedule()`；被唤醒后重新取得 `slock` 并检查 `owned`。[net/core/sock.c:3145](../../../src/linux-6.18/net/core/sock.c#L3145)

因此 `lock_sock()` 返回后，进程可以执行较长的工作，必要时睡眠；它并没有一直关 BH。普通 `tcp_sendmsg()` 和 `tcp_recvmsg()` 的主体被这对逻辑锁包围，见 [net/ipv4/tcp.c:1408](../../../src/linux-6.18/net/ipv4/tcp.c#L1408)、[net/ipv4/tcp.c:2913](../../../src/linux-6.18/net/ipv4/tcp.c#L2913)。等待网络数据时则主动交还拥有权：`sk_wait_event` 在等待前 `release_sock()`，醒来后再 `lock_sock()`，避免自己占着 socket 却等待收包路径更新它。[include/net/sock.h:1193](../../../src/linux-6.18/include/net/sock.h#L1193)

### 包到达：可以处理就处理，否则排队

对于这里讨论的非 LISTEN socket，`tcp_v4_rcv()` 在 `bh_lock_sock_nested()` 后执行：

```c
if (!sock_owned_by_user(sk))
        ret = tcp_v4_do_rcv(sk, skb);
else if (tcp_add_backlog(sk, skb, &drop_reason))
        goto discard_and_relse;
```

代码：[net/ipv4/tcp_ipv4.c:2370](../../../src/linux-6.18/net/ipv4/tcp_ipv4.c#L2370)。没有进程拥有者时，收包方在 `slock` 下执行 TCP；有拥有者时只完成允许的收包整理并排队，不并发执行该连接的主 TCP 状态机。`owned` 并不意味着结构体里任何统计字段都绝对不变。

LISTEN 分支在该锁之前单独处理，见 [net/ipv4/tcp_ipv4.c:2363](../../../src/linux-6.18/net/ipv4/tcp_ipv4.c#L2363)。因此不能把这段逻辑推广成“所有 TCP 包都竞争 listener 的这把锁”；监听扩展见 B3。

### 释放拥有权：先完成积压，再交接

`release_sock()` 取得 `slock`，调用 `__release_sock()` 清 backlog，执行协议的 `release_cb`，最后才清 `owned`、唤醒等待者并释放 `slock`。[net/core/sock.c:3731](../../../src/linux-6.18/net/core/sock.c#L3731)

清 backlog 的关键是**摘走一批包后，释放自旋锁，但继续保留逻辑拥有权**：

```c
while ((skb = sk->sk_backlog.head) != NULL) {
        sk->sk_backlog.head = sk->sk_backlog.tail = NULL;
        spin_unlock_bh(&sk->sk_lock.slock);
        /* 逐个 sk_backlog_rcv()；适当 cond_resched() */
        spin_lock_bh(&sk->sk_lock.slock);
}
sk->sk_backlog.len = 0;
```

代码：[net/core/sock.c:3163](../../../src/linux-6.18/net/core/sock.c#L3163)。实际循环还保留下一包指针、预取和清理链表标记；每处理一组包才考虑调度。

| 时间 | 进程拥有者 | 另一个 CPU 的收包路径 |
| --- | --- | --- |
| T0 | `owned=1`，摘走批次 A | 需要 `slock` 才能碰共享 backlog |
| T1 | 放开 `slock`，处理 A | 能取得 `slock`，发现 `owned=1`，把新包挂成批次 B |
| T2 | 重新取得 `slock`，检查到 B，继续摘走处理 | 不会与拥有者同时运行该连接的主协议处理 |
| T3 | 在 `slock` 下确认无积压，完成回调，清 `owned` | 清零与交接之间没有可以漏挂一批包的空窗 |

这解释了两个容易误读的地方。第一，`release_sock()` 可能做大量 TCP 工作，耗时不等于一次 unlock。第二，解锁前可以重新出现 backlog，所以只摘取一次后立即清 `owned` 是不够的。

`tcp_release_cb()` 还处理被推迟的发送、定时器、MTU 和 ACK 工作。它是同一种“拥有者收尾”策略的延伸。[net/ipv4/tcp_output.c:1287](../../../src/linux-6.18/net/ipv4/tcp_output.c#L1287)；回调绑定见 [net/ipv4/tcp_ipv4.c:3504](../../../src/linux-6.18/net/ipv4/tcp_ipv4.c#L3504)。

### 为什么不边处理边把 `len` 减掉？

因为生产者可以趁拥有者放开 `slock` 时继续灌包。若每处理一个就立刻恢复额度，拥有者可能持续接收新工作，迟迟不能离开释放路径。`__release_sock()` 只在整轮清空后把 `len` 归零；注释明确将它与避免洪泛导致无限处理循环联系起来。[net/core/sock.c:3193](../../../src/linux-6.18/net/core/sock.c#L3193)

6.18 的 TCP 入队阈值是：

```text
limit = min(2 × sk_rcvbuf + sk_sndbuf / 2 + 64 KiB, UINT_MAX)
检查量 = sk_backlog.len + sk_rmem_alloc
```

见 [net/ipv4/tcp_ipv4.c:2130](../../../src/linux-6.18/net/ipv4/tcp_ipv4.c#L2130)、[include/net/sock.h:1116](../../../src/linux-6.18/include/net/sock.h#L1116)。已排队的旧包处理后可能计入 `sk_rmem_alloc`，但本轮 backlog 计数尚未清零；这解释了为何不能直接拿一个 `sk_rcvbuf` 同时限制两个计数。

这是带余量的资源限制，不是精确的瞬时内存上限或固定执行时间上限：检查不预先加入当前 skb 的 `truesize`，允许一个较大的包进入；TCP 还会在检查前尝试与尾包合并，甚至在超过阈值时继续合并。源码用分片容量等约束控制这种合并。[net/ipv4/tcp_ipv4.c:2055](../../../src/linux-6.18/net/ipv4/tcp_ipv4.c#L2055)

## 4. 演进：内存上限与调度公平性不断重新平衡

以下数据均来自提交正文，不是本文重新测量；不能作为任意设备上的预期收益。

| commit / 作者 | 设计动机 | 提交正文的实验或性能数据 |
| --- | --- | --- |
| `1da177e4c3f41524e886b7f1b8a0c1fc7321cac2` / Linus Torvalds，2005 | Git 初始导入时已有双重锁和 backlog 清理。**它不是这个设计的引入提交**；最初作者、提交和动机未确认。头文件只留下“约 2.3.5 起兼作进程间睡眠锁”的注释。 | 未提供相关数据。 |
| `8eae939f1400326b06d0c9afe53d2a484a326871` / Zhu Yi，2010 | 给 socket backlog 加上限，防止边 drain 边被发送者填满，绕过接收缓冲限制。 | UDP loopback netperf 多发送者对单接收者触发 OOM；指出可被非特权用户利用，所有使用 backlog 的协议可能受影响。没有吞吐数字。 |
| `5413d1babe8f10de13d72496c12b862eef8ba613` / Eric Dumazet，2016 | backlog 回调已能在进程上下文运行，因此 drain 时允许 BH，缩短其他收包工作的等待。 | 曾采样到 `__release_sock()` 连续占 CPU **超过 5 ms**，NIC ring 填满后丢包；未给改后分位延迟。 |
| `4f693b55c3d2d2239b8a0094b518a1e533cf75d5` / Eric Dumazet，2018 | 尾包合并减少拥有者待处理的 skb，也能处理 GRO 不聚合的纯 ACK；平衡软中断与拥有者的工作量。 | 无 GRO 接收端吞吐约 **+60%**；测得 `release_sock()` 延迟降低约 **1000 倍**。正文未提供完整测试平台。 |
| `ec00ed472bdb7d0af840da68c8c11bff9f4d9caa` / Eric Dumazet，2024 | 将阈值中的接收缓冲贡献翻倍，吸收 backlog 末尾才清计数导致的重叠，避免高速流被过早丢弃。 | 报告观察到可疑 `SOCKET_BACKLOG` 丢包；未提供量化性能数据。 |
| `16c610162d1f1c332209de1c91ffb09b659bb65d` / Eric Dumazet，2025 | 改为每约 16 包才调用一次 `cond_resched()`；拥有者让出 CPU 后若长时间不能回来，正常收到的包也可能等到对端 TLP/RTO 超时。 | 4 条高吞吐流集中到一个 CPU；10 秒统计修改前 19,046,186 个 `TcpOutSegs`、1,471 个重传、1,397 个 timeout、114 个 spurious RTO；修改后 19,218,936 个 `TcpOutSegs`，所展示的其余异常计数不再出现。 |

历史取证可复现：

```bash
git blame -L 79,87 -- include/net/sock.h
git blame -L 3163,3198 -- net/core/sock.c
git log -S 'coalescing to last skb' -- net/ipv4/tcp_ipv4.c
git blame -L 2130,2147 -- net/ipv4/tcp_ipv4.c
git show 8eae939f1400326b06d0c9afe53d2a484a326871
git show 16c610162d1f1c332209de1c91ffb09b659bb65d
```

## 5. 取舍：避免上下文互相阻塞，代价转移到了拥有者

得到的是通用同步语义：应用无需自己协调软中断；不同连接可以并行；同一个连接的主协议状态保持串行；慢应用引起的临时积压受内存限制。收包还能把包交给正在操作该连接的线程处理，从代码可推断这有机会复用其缓存，但本文未量化这个收益。

付出的是排队与职责转移。一次应用调用的末尾可能代做收包、ACK 和定时器收尾；应用侧延迟因此受对端流量影响。`perf` 中记在应用线程名下的 `__release_sock()`，未必是应用本身做了大量业务计算。

同一个 socket 被许多线程同时操作、收包 CPU 与应用 CPU 分离、拥有者被调度器长时间挂起时，锁和缓存迁移更容易成为瓶颈。backlog 限制会把资源压力转换为丢包与重传；提高上限又会扩大积压与尾延迟。2024 年加余量和 2025 年降低让出频率，分别说明“越小越安全”和“越频繁调度越公平”都不是单调成立的性能规则。

对已固定单核、无阻塞、连接归属明确的数据面，这套跨上下文交接常常是额外成本。但直接删掉它，需要先改变执行与 API 约束。

## 6. 对照：用户态栈通过限制谁能执行，减少运行时同步

**lwIP 2.1.3** 的核心采用单执行上下文；OS 模式通常由核心线程执行协议逻辑，其他线程通过消息传递使用顺序/socket API，也可启用核心锁。raw API 的回调不能阻塞。因而它可以把串行化放到入口和执行模型中；代价是全局核心的并发能力与应用调用方式受到约束。这里比较的是执行模型，不是说 lwIP 没有任何锁或队列。[官方 `main_page.h` 的 multithreading / raw API 说明](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_1_3_RELEASE/doc/doxygen/main_page.h)

**Seastar 的 native TCP 栈** 建立在每核协作调度与 share-nothing 模型上，跨核通过消息传递。由此可推断，连接状态留在所属 shard 时，不需要复制 Linux 这套“任意应用线程与软中断交接拥有权”的协议。代价是应用必须遵守异步执行和对象归属约束。Seastar 也能选择操作系统网络栈；该模式仍承担内核 socket 同步成本。[官方教程](https://raw.githubusercontent.com/scylladb/seastar/master/doc/tutorial.md)

与你熟悉的 VPP/DPDK 执行思路的连接是：先建立连接/流的执行归属，再讨论锁能不能省。队列与背压依然需要，只是它们可能位于线程间消息通道或应用事件队列。

## 7. 验证：区分排队时间、拥有权争用和 drain 工作

以下是实验方案，**本轮未运行压测或修改运行中内核设置**。先确认实验机运行的内核与笔记基准一致，且可用 BTF/kprobe。测试使用自己控制的两端；固定流量、CPU 亲和性与 GRO 配置后，再比较单流/多流、应用与 RX 同核/异核。

用 `nstat -az TcpExtTCPBacklogDrop TcpExtTCPBacklogCoalesce` 记录前后差值，检查 backlog 丢包与合并。计数器名称来自 [net/ipv4/proc.c:222](../../../src/linux-6.18/net/ipv4/proc.c#L222)、[net/ipv4/proc.c:245](../../../src/linux-6.18/net/ipv4/proc.c#L245)。这些是网络命名空间累计量，不是单连接指标。

用 bpftrace 测目标应用线程调用 `release_sock()` 的墙钟耗时：

```bpftrace
kprobe:release_sock /pid == $1/ { @start[tid] = nsecs; }
kretprobe:release_sock /@start[tid]/ {
  @release_us = hist((nsecs - @start[tid]) / 1000);
  delete(@start[tid]);
}
```

以目标进程 PID 作为脚本参数。该直方图包含 backlog 工作、协议回调以及被调度走的时间，不能单独归因给锁。再用 `perf record -g -p <PID> -- sleep 15` / `perf report` 看 CPU 样本是否集中在 `__release_sock()` 与 TCP 收包；用调度 trace 区分“正在处理”和“拥有权还在但线程没运行”。进程过滤不覆盖其他 CPU 的收包软中断，观察整条路径还需系统级采样。

如果看到 backlog drop 增长，不能仅凭它就提高缓冲上限；先区分消费者拿不到 CPU、跨核争用、GRO 合并差以及真正的接收内存压力。B1 解释的是积压为何出现；A2 解释这些额度如何进入更大的内存约束。
