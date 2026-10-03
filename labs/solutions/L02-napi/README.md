# L02 参考推导

本篇回答：怎样解释预算与批量分布？前置：[L02 题面](../../L02-napi/)。预计阅读 8 分钟。阅读顺序是题面、自己的观察表、本文件、`napi.bt` 和 `budget-round.sh`；后两者分别负责观察与保存/恢复一个 sysctl。运行及性能结论【未实跑】，没有保证任一 VM 支持通知合并。

`__napi_poll` 用 `n->weight` 调用驱动，再记录 `work` 和该权重，见 `/home/chen/code/linux-lab/src/linux-6.18/net/core/dev.c:7580`。`net_rx_action` 使用另一份总预算，每次 poll 后扣减，见 `/home/chen/code/linux-lab/src/linux-6.18/net/core/dev.c:7783`；循环在总预算或时间限制触发时让出。因此一轮的累计工作可在最后一次完整 poll 后超过初始总预算，不是把最后一次 poll 的参数强行裁成剩余预算。

`work` 是驱动返回的工作量。virtio RX 的 `virtnet_poll` 返回 received，见 `/home/chen/code/linux-lab/src/linux-6.18/drivers/net/virtio_net.c:3114`；不能把所有设备、TX poll 与 GRO 后的 skb 都按同一个“线上包”口径解释。tracepoint 在返回后触发，也不提供 poll 开始时间。脚本测得的是 NET_RX handler 包围时间，其取样以本实验普通软中断模式为前提；更换 threaded NAPI 或 PREEMPT_RT 场景需要重新设计配对与指标。

<details><summary>四道思考题答案</summary>

1. 两个 budget 属于不同层次。sysctl 限制一轮软中断总工作；事件中的 budget 是本次回调传入的实例权重。
2. 按设备、NAPI 指针与 CPU 拆开，检查是否混入 TX NAPI、空轮询或其他设备；不要直接删去零值以美化图形。
3. 不能下此结论。先看队列、IRQ affinity、RSS/RPS、流的哈希分布以及 vCPU 数；工作总额与分流策略不是同一开关。
4. 提交能力查询、设置失败及错误信息、未变化读回值，加上三轮预算结果和参数恢复记录；不编造中断合并改善效果。

</details>

要点回顾：两层预算；实例分组；同负载比较；支持与效果分开；退出后核对恢复。与 DPDK/VPP 对照：单个 RX burst 的最大数量比较像实例 weight，总 softirq 预算还涉及内核调度公平性；二者都不能替代 RSS/worker 分配。未确认项：实际挂载、实际 work 分布、设备 coalescing 能力及测量扰动。
