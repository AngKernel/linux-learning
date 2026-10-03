# 01 执行上下文：先判断谁在执行

本篇回答：网络代码由谁执行？什么时候能睡眠？为什么把工作转给 workqueue？
前置阅读：无；熟悉 C 函数调用即可。预计阅读时间：15 分钟。
源码基准：Linux v6.18；以下表格以非 PREEMPT_RT 内核为准。这里的“抢占”指任务调度抢占，不把硬中断打断算作任务抢占。

## 上下文决定能做什么

进程上下文（process context）表示代码代表一个可调度的 task 执行，例如应用调用 socket 系统调用。硬中断（hard IRQ）是 CPU 响应设备事件时进入的处理程序；软中断（softirq）是内核延后处理的一类机制。它们不是“更高优先级的普通函数”。

| 上下文 | 可睡眠/等待 mutex | 调度抢占 | 硬中断可打断 | 分配内存的入门规则 | 网络例子 |
|---|---|---|---|---|---|
| 系统调用中的进程上下文 | 可，前提是不在原子临界区 | 取决于抢占配置及临界区 | 通常可 | 可睡眠处用 GFP_KERNEL | `net/socket.c:2269` |
| 硬中断处理程序 | 不可 | 不可 | 常规入口本地 IRQ 关闭；NMI 另论 | 不能触发睡眠，优先预分配；不能把 GFP_ATOMIC 当无限通行证 | `drivers/net/ethernet/intel/e1000/e1000_main.c:3748` |
| 软中断处理程序 | 不可 | 非 RT 内核中不可 | 通常可 | 常见 GFP_ATOMIC，也要处理失败 | `net/core/dev.c:7745` |
| tasklet（小任务） | 不可 | 同软中断 | 通常可 | 同软中断 | `drivers/net/ethernet/silan/sc92031.c:833` |
| 普通 workqueue 的 worker | 可，前提同进程上下文 | 取决于抢占配置及临界区 | 通常可 | 可睡眠处用 GFP_KERNEL | `drivers/net/ethernet/intel/e1000/e1000_main.c:3505` |
| 普通内核线程 | 可，前提同进程上下文 | 取决于抢占配置及临界区 | 通常可 | 由当时所在临界区决定 | `net/core/dev.c:7735` |

表中的 workqueue 指普通线程化 workqueue；不能推广到所有 workqueue 类型。内核线程也可能进入禁止睡眠的区段，因此“当前有 PID”不能推出“这里可以睡眠”。PREEMPT_RT 会改变 softirq 与 spinlock 的抢占语义，见 `Documentation/locking/locktypes.rst:210`、`Documentation/locking/locktypes.rst:245`。

## 从 IRQ 到 NAPI：安排工作与执行工作

驱动把 `e1000_intr` 注册为 IRQ handler，见 `drivers/net/ethernet/intel/e1000/e1000_main.c:250`。其中只摘调度部分：

```c
if (likely(napi_schedule_prep(&adapter->napi))) {
    /* 省略统计复位 */
    __napi_schedule(&adapter->napi);
}
```

出处：`drivers/net/ethernet/intel/e1000/e1000_main.c:3776`。这里安排 NAPI（收包轮询机制）运行；不是在这一行调用驱动轮询函数。注册轮询回调的位置是 `drivers/net/ethernet/intel/e1000/e1000_main.c:1009`，实际函数为同文件 `drivers/net/ethernet/intel/e1000/e1000_main.c:3798` 的 `e1000_clean`。

```mermaid
flowchart LR
  IRQ[硬中断 e1000_intr] --> S[安排 NAPI]
  S --> RX[NET_RX_SOFTIRQ]
  RX --> A[net_rx_action]
  A --> P[napi_poll]
  P --> C[驱动 poll 回调]
```

软中断注册见 `net/core/dev.c:13064`；`net_rx_action` 从本 CPU 的轮询列表取 NAPI 并调用 `napi_poll`，见 `net/core/dev.c:7783`。这是传统路径。不能据此断言“所有网络收包都在软中断”。

threaded NAPI（线程化 NAPI）可创建专用线程，见 `net/core/dev.c:1636`。它调用的轮询循环在进入回调前执行 `local_bh_disable()`，并在离开该区段后才执行 `cond_resched()`，见 `net/core/dev.c:7696`。即使外层是内核线程，驱动 poll 也不能随意睡眠。`ksoftirqd` 同样是承载软中断执行的线程，并不会把软中断回调变成可任意阻塞的函数；入口见 `kernel/softirq.c:1055`。

## tasklet、workqueue 与内核线程

tasklet 依托软中断运行，同一个 tasklet 的回调不会同时在两个 CPU 上执行，但不同 tasklet 仍可能并发。核心调用路径见 `kernel/softirq.c:903`、`kernel/softirq.c:950`。网络例子 `sc92031_tasklet` 检查事件后分别处理收发，见 `drivers/net/ethernet/silan/sc92031.c:833`；注册与安排分别在同文件 `drivers/net/ethernet/silan/sc92031.c:1452`、`drivers/net/ethernet/silan/sc92031.c:893`。不要把 tasklet 理解为一个可睡眠的线程。

workqueue（工作队列）适合把可延后的工作交给 worker。e1000 超时处理中有：

```c
schedule_work(&adapter->reset_task);
```

出处：`drivers/net/ethernet/intel/e1000/e1000_main.c:3502`。真正复位发生在 `e1000_reset_task`，其代码取得 RTNL 锁后调用复位逻辑，见同文件 `drivers/net/ethernet/intel/e1000/e1000_main.c:3505`。安排者返回与 worker 开始运行之间没有固定时间间隔。不要据函数调用邻接关系画出同步执行顺序。

普通内核线程与 worker 都由调度器调度；前者通常由子系统管理循环和退出，后者由 workqueue 基础设施管理。NAPI 线程创建处与回调处之间的关系，就是读取内核线程代码时应追踪的“创建入口 → 线程主函数”。

## 动手：看同一 CPU 的不同工作

以下命令未在 v6.18 实验内核实跑；应在实验 VM 执行。它们只读取计数，不证明完整调用关系。

```sh
cat /proc/interrupts
cat /proc/softirqs
ps -eLo pid,tid,psr,comm | rg 'ksoftirqd|kworker|napi/'
```

在另一终端向实验 VM 发流量，再读前两项的增量。回环流量能产生协议栈活动，但不会产生物理网卡 IRQ。观察不到 `napi/` 线程也正常：是否启用 threaded NAPI 取决于配置和设备设置。`/proc/softirqs` 的 NET_RX 计数是处理次数，不是精确包数。

## 要点回顾

- 是否可以睡眠由当前上下文和持有的锁共同决定。
- 中断打断与调度抢占是两个不同问题。
- 安排 NAPI/work 与执行回调之间存在异步边界。
- 传统 NAPI 常在 NET_RX 软中断执行；threaded NAPI 是另一种调度方式。
- 内核线程中的临界区仍然可能禁止睡眠。

## 自测

1. `schedule_work()` 返回时，复位一定完成了吗？
2. `ksoftirqd` 有 PID，为什么软中断回调仍不能任意睡眠？
3. 用回环流量能验证物理网卡 IRQ 分布吗？

<details><summary>答案</summary>

1. 不一定，只表示安排工作；需要具体同步机制才能等待完成。
2. 执行的是 softirq 处理区段，要遵守该上下文的限制。
3. 不能。它可以验证部分协议栈活动，不能验证物理驱动和硬件中断路径。

</details>

## 与 DPDK/VPP 的对照

DPDK 的常驻轮询 lcore 帮助理解 NAPI 的批量 poll，但 NAPI 由内核调度、受 budget 和其他任务影响。VPP worker 的运行线程更固定；内核同一连接相关代码可能先后由 IRQ、softirq 和系统调用触发。类比到“批量处理”即可，不要进一步假设 CPU 所有权或允许的阻塞行为相同。
