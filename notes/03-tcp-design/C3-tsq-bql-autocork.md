# C3. TSQ、BQL、autocorking：控制排队的位置与粒度

本篇回答：为何 socket 有发送缓冲还需 TSQ/BQL？小写入为何有时被延后？前置阅读：A2、B1、C2。预计阅读：11 分钟。源码基准：Linux v6.18。

## 1. 问题

大发送缓冲有利于吞吐，却可能把许多数据提前压进 qdisc（排队规则）和 NIC，排队时延随之膨胀。另一端的小 write 又可能浪费一个发送对象只装少量字节。三个机制分别管流、设备队列和合包时机。

## 2. 约束

TCP 需要足够在途数据利用链路，硬件队列也不能饿死；高优先级流应有机会及时进入；应用不一定会正确使用显式 cork/批量 API。TX 完成通知可能延迟，必须避免节流后无人恢复。

## 3. 方案

| 机制 | 控制范围与反馈 | 代码 |
|---|---|---|
| TSQ（TCP Small Queues，小发送队列） | 每 socket 已下发到 qdisc/设备的内存占用；释放反馈触发继续发送 | `net/ipv4/tcp_output.c:1208`、`net/ipv4/tcp_output.c:2770` |
| BQL（Byte Queue Limits，字节队列限制） | 每设备 TX queue 的已提交/已完成字节，自适应限制驱动排队 | `include/linux/netdevice.h:3750`、`include/linux/netdevice.h:3832` |
| autocorking（自动暂缓小写入） | 当前 skb 未达目标大小且已有数据在下层时，短暂等待后续写入合并 | `net/ipv4/tcp.c:735` |

TSQ 使用 `sk_wmem_alloc`，不是 A2 的 `sk_wmem_queued`。当前限额考虑 skb `truesize`、pacing rate 和 `tcp_limit_output_bytes`，并含避免停滞的例外；不是历史固定 128 KB。`tcp_wfree()` 不能直接从析构中重新发包，所以安排 per-CPU BH work，见 `net/ipv4/tcp_output.c:1350`。

BQL 要靠驱动正确报告发送和完成量；它不是每 TCP 流的公平调度器，也不识别 TCP ACK。autocorking 借用 TSQ 恢复机制，`tcp_push()` 设置节流位后再次检查完成竞争（`net/ipv4/tcp.c:759`）。等待时间由已有排队动态决定，不是固定延时器；也不能与等待 ACK 的 Nagle 规则混为一谈。

## 4. 演进

| commit / 作者 | 动机 | 正文数据 |
|---|---|---|
| `114cf5802165` / Tom Herbert | 给每 TX queue 接入动态字节限制。 | 该提交未提供性能数据。 |
| `46d3ceabd8d9` / Eric Dumazet | 引入 TSQ，减少单流在 qdisc/设备的积压与 RTT 偏差。 | 作者 tg3/ixgbe、pfifo_fast 测试，千兆缓冲从约 50 ms 到小于 1 ms、百兆从 132 ms 到小于 8 ms，称吞吐未降；不是当前任意设备的保证。 |
| `f54b311142a9` / Eric Dumazet | 利用 TSQ/TSO/pacing 机会把小 write 合并。 | 4 路、128 B TCP_STREAM 输出吞吐 6624.89→9410.39，task-clock 40045.86→35209.44 ms；正文未明确打印吞吐单位，保留原值不擅自标单位。 |
| `fd0406e5ca53` / Tejun Heo | TSQ 从 tasklet 迁到 BH workqueue，替换弃用接口。 | 该提交未提供性能数据；作者预期语义等价。 |

## 5. 取舍

数据尽量留在可调度的软件层，减少不可控制的设备积压；代价是完成反馈、节流状态与并发恢复更复杂。小写入合并减少包数，也可能改变应用感知延迟。队列过小与完成反馈过慢可能降低利用率，因此不能一味把所有限额设到最小。

## 6. 用户态对照

lwIP 2.2.0 的 `tcp_pbuf_prealloc()` 使用更多数据提示和 Nagle 状态预留空间，说明“猜后续写入能否合并”的策略并非内核专属；它不等价于 Linux 以 TX completion 驱动的 TSQ。[固定 tcp_out.c](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_2_0_RELEASE/src/core/tcp_out.c)

## 7. 验证

目标机先记录 qdisc、驱动 BQL sysfs 是否存在及 `net.ipv4.tcp_autocorking`。同一组小写入工作负载只切 autocorking，比较完成延迟、吞吐和 CPU，再恢复原值。没有 BQL 节点可能是驱动未接入；loopback 不能模拟真实 NIC 队列。未实际运行。

## 要点回顾

- TSQ 按 socket，BQL 按设备队列，autocorking 选择合包时机。
- TX completion 与 TCP ACK 的反馈层级不同。
- 6.18 TSQ 使用 BH workqueue，不照抄早期 tasklet 图。

## 自测

1. BQL 保证 TCP 流之间公平吗？
2. TSQ 控制整个未 ACK 字节量吗？
3. autocorking 是否固定等一个 RTT？

<details><summary>答案</summary>

1. 不保证，它限制设备队列。2. 不是，它约束下层排队占用，TCP 重传存量另有生命周期。3. 不是，依赖已有下层发送/完成动态。

</details>

## 与 DPDK/VPP 的对照

PMD ring 深度、软件队列和 burst 大小同样会制造排队；绕过 qdisc 不等于排队消失。专用发送调度可以更直接，但仍要按流和按设备分别控制容量，避免一个大流占满 ring。
