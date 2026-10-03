# D1. 定时器：异常兜底与精细发送节奏分工

本篇回答：TCP 为何同时使用时间轮和 hrtimer？定时器到期是否立即执行协议工作？前置阅读：B1、C1。预计阅读：9 分钟。源码基准：Linux v6.18。

## 1. 问题

大量连接需要“若 ACK 还没到就重传”的保险，也需要细粒度发送节奏。为每个远期超时都追求纳秒精度，会把维护成本施加给绝大多数到期前就被取消的定时器。

## 2. 约束

通用内核要兼顾大量连接、空闲省电、CPU 调度与回调上下文。到期时 socket 可能被应用拥有；即使时钟精细，执行也可能因为 CPU 忙或同步而延后。

## 3. 方案

`tcp_init_xmit_timers()` 在 `net/ipv4/tcp_timer.c:895` 分两组初始化：

| 类型 | 当前用途 | 证据 |
|---|---|---|
| `timer_list` 时间轮定时器 | 写侧超时、普通 delayed ACK、keepalive | `net/ipv4/inet_connection_sock.c:758` |
| `hrtimer` 高精度定时器 | pacing 与 compressed ACK（压缩 ACK） | `net/ipv4/tcp_timer.c:899` |

6.18 的普通 timer wheel 是分层、非级联时间轮：到期越远，桶粒度越粗，减少维护与唤醒，设计解释见 `kernel/time/timer.c:65`。不能把历史经典级联时间轮的图直接当当前实现。

写 timer 由 `icsk_pending` 区分重传、零窗口探测、loss probe 和 RACK 重排序超时，见 `net/ipv4/tcp_timer.c:691`。因此一个 timer 字段不等于只有一种协议事件。`tcp_write_timer()` 若发现 socket 被用户拥有，会记 deferred 标记交给释放回调，而非并发改连接，见 `net/ipv4/tcp_timer.c:726`。

pacing timer 使用 `CLOCK_MONOTONIC` 与 soft hrtimer 模式；compressed ACK 也是高精度路径。不能简单说“TCP 所有 ACK timer 都是时间轮”。

## 4. 演进

| commit / 作者 | 动机 | 正文数据 |
|---|---|---|
| `500462a9de65` / Thomas Gleixner | 时间轮改为非级联，避免大量本会取消的 timeout 做级联维护，并为快速查下一次到期铺路。 | 测试称未见性能退化；未给量化吞吐/延迟性能数据。提交中的粒度表属于当时实现。 |
| `73a6bab5aa2a` / Eric Dumazet | pacing timer 改用 softirq hrtimer，省去经 tasklet 的额外调度与原子操作。 | 该提交未提供性能数据。 |

第一条是通用 timer 子系统改造，不是 TCP 首次使用定时器。当前粒度以 6.18 和具体 HZ 为准。

## 5. 取舍

粗粒度超时维护便宜，但可容忍的延后取决于用途；pacing 更精细，付出高精度 timer 和调度成本。把 RTO 估计精度、timer 到期精度、回调实际执行时刻分开，才不会误读测量。

## 6. 用户态对照

lwIP 2.2.1（`77dcd25a72509eb83f72b033d219b1d40cd8eb95`）用 `tcp_fasttmr()`/`tcp_slowtmr()` 分别按 250/500 ms 的基础节奏处理 TCP 定时工作，见 `src/core/tcp.c:236`。简单轮次模型便于小系统，但粒度与扫描成本限制低 RTT 大规模场景。[固定源码](https://github.com/lwip-tcpip/lwip/blob/77dcd25a72509eb83f72b033d219b1d40cd8eb95/src/core/tcp.c#L236)

## 7. 验证

目标机用 `perf list` 确认 `timer:timer_expire_entry` 与 `timer:hrtimer_expire_entry`，在既有受控连接上采样并解码回调函数。定义核对于 `include/trace/events/timer.h:92`、第 259 行。分别比较计划时刻与实际回调时刻，不能只拿回调间隔当 timer 精度。未运行。

## 要点回顾

- 大量 timeout 适合便宜的粗粒度管理。
- 精细 pacing 有独立 hrtimer。
- 到期与协议处理之间仍有上下文和锁的限制。

## 自测

1. RTT 用微秒估计是否意味着 RTO timer 也纳秒到期？
2. 写 timer 到期时 socket 被拥有怎么办？
3. compressed ACK 与普通 delayed ACK 必然用相同 timer 吗？

<details><summary>答案</summary>

1. 不意味着，估计和调度是两层。2. 标记 deferred，交给释放回调处理。3. 不同，前者还有 hrtimer 路径。

</details>

## 与 DPDK/VPP 的对照

用户态事件循环也要选择时间轮、堆或高精度调度。绑核可以减少某些调度扰动，但长批处理仍会拖延 timer；省掉内核 timer 不代表省掉协议对时间的要求。
