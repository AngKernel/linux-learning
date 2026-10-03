# 追踪点的 v6.18 源码证据

本篇回答：每个探测点在哪里定义、为什么避开 inline、字段怎样核对？前置阅读：本目录 `README.md`。预计阅读时间：8 分钟。

本次使用前已执行 `git describe --always --dirty --tags`，结果为 `v6.18`。下表路径相对于 `/home/chen/code/linux-lab/src/linux-6.18`。函数定义都已检查，**均非源码中的 inline 函数**；优化器仍可能内联/克隆静态函数，因此启动 wrapper 必须查询实际探测列表。

| 阶段/脚本 | 探测函数 | 已核对的定义 |
|---|---|---|
| virtio 通知 handler | `vring_interrupt` | `drivers/virtio/virtio_ring.c:2693` |
| NET_RX softirq | `net_rx_action` | `net/core/dev.c:7745`，static 非 inline |
| virtio RX poll | `virtnet_poll` | `drivers/net/virtio_net.c:3114`，static 非 inline |
| GRO 入口 | `gro_receive_skb` | `net/core/gro.c:624` |
| 接收协议分发核心 | `__netif_receive_skb_core` | `net/core/dev.c:5849`，static 非 inline |
| IPv4 单包入口 | `ip_rcv` | `net/ipv4/ip_input.c:564` |
| IPv4 list 入口 | `ip_list_rcv` | `net/ipv4/ip_input.c:648` |
| TCPv4 入口 | `tcp_v4_rcv` | `net/ipv4/tcp_ipv4.c:2202` |
| established 接收处理 | `tcp_rcv_established` | `net/ipv4/tcp_input.c:6259` |
| socket 可读通知 | `sock_def_readable` | `net/core/sock.c:3542` |
| 任务唤醒尝试 | `try_to_wake_up` | `kernel/sched/core.c:4143` |

`napi_gro_receive` 在 `include/linux/netdevice.h:4190` 是 `static inline`，内部直接转到 `gro_receive_skb`。因此不能继续沿用很多旧文章里的 `kprobe:napi_gro_receive`。`gro_receive_skb` 的入口/出口也有 tracepoint，但这里保留 kprobe/kretprobe，供同一种计数和包围耗时方法跨阶段对照。

| 事件 | 字段及证据 | 解释边界 |
|---|---|---|
| `irq:irq_handler_entry` / `irq_handler_exit` | `irq`、`name` 在 `include/trace/events/irq.h:53`；返回事件 `include/trace/events/irq.h:83` | handler 运行时间，不含硬件把中断递送到 CPU 前的等待 |
| `irq:softirq_entry` / `softirq_exit` | 事件类和 `vec` 在 `include/trace/events/irq.h:103`；实例 `include/trace/events/irq.h:128`、`include/trace/events/irq.h:142` | CPU 上一次 handler 执行，不是软中断 raised 到运行的队列延迟 |
| `napi:napi_poll` | `napi`、`dev_name`、`work`、`budget` 在 `include/trace/events/napi.h:14` | poll 返回时驱动报告的工作量；不是必然等于所有物理包 |
| `skb:kfree_skb` | `reason`、`location` 等在 `include/trace/events/skb.h:24` | 软件释放位置和原因，不覆盖全部硬件/驱动前置丢包 |

softirq 编号在 `include/linux/interrupt.h:548` 开始的 enum 中，NET_TX=2、NET_RX=3。drop reason core enum 见 `include/net/dropreason-core.h:139`；打印符号映射来自 tracepoint 的 `TP_printk`，运行时查 `events/skb/kfree_skb/format`。

`virtnet_poll_tx` 的普通 skb 路径调用 `free_old_xmit`，可回收 TX 后仍返回 0，见 `drivers/net/virtio_net.c:3255` 后的函数体。`softirq-napi.bt` 用 NAPI 指针把实例分开，不能把同设备的零工作量直接解读为 RX 空轮询。

`sock_def_readable` 只在有 sleeper 等条件下调用唤醒；`try_to_wake_up` 是整个系统共用函数，计数包含与网络无关的任务，也可能返回失败。本库没有将它绑定为某个 skb 的最终用户线程唤醒。计时使用当前执行者的 CPU/TID，不使用它推导应用已经读到数据。

ftrace 子树过滤依据 `Documentation/trace/ftrace.rst:340`；`available_filter_functions` 的语义见 `Documentation/trace/ftrace.rst:355`。其集合不等同 kprobe 可探测集合。GDB 的 `tcp_v4_rcv` 断点依据同一函数定义，无独立硬编码地址。

## 要点回顾

- 源码非 inline 是必要核对，实际挂载还取决于生成的符号与内核配置。
- v6.18 用 `gro_receive_skb` 替代 inline 的 GRO wrapper。
- list 分发与 TX NAPI 的工作量语义会改变计数解释。
- 全局任务唤醒探针不能自动归因给某个网络包。

## 自测题

1. 为什么仅运行 `rg napi_gro_receive` 不能确认 kprobe 可用？
2. 为什么 `work=0` 不能证明驱动什么都没做？
3. 为什么 `try_to_wake_up` 次数不能当作接收包数？

<details><summary>答案</summary>

1. 搜索可能只命中调用或声明；本版本定义是 inline，必须继续检查定义与实际符号。
2. TX poll 可以回收完成描述符却按预算语义报告零 RX 工作量。
3. 唤醒由任务状态决定，可合并、失败，也包含系统里其他唤醒来源。

</details>

## 与 DPDK/VPP 的对照

这里像选择 VPP node 的入口计数器，但 compiler inline、GRO 合并和内核唤醒让计数单位更容易变化。DPDK burst 数、descriptor 数、mbuf 数尚需区分，内核还需区分 IRQ、poll、skb/list 和任务状态变化。
