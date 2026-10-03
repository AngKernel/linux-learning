# C4. busy polling：让等待者主动推进收包

本篇回答：socket busy polling 是否绕过内核？低延迟收益付给谁？前置阅读：C1、B3。预计阅读：8 分钟。源码基准：Linux v6.18。

## 1. 问题

包已到设备队列，应用却可能还在等中断、softirq 和唤醒。低延迟应用愿意花 CPU 提前查看队列，把这段等待缩短。

## 2. 约束

CPU 与能源不是免费资源；NAPI 可能同时被其他路径调度；应用关心的连接还必须和正确的 NAPI 实例关联。共享主机不能假定任意进程都能长期独占一个核。

## 3. 方案

`sk_busy_loop()` 读取 `sk_napi_id`，有效时调用 `napi_busy_loop()`，并带上偏好与预算；受 `CONFIG_NET_RX_BUSY_POLL` 控制，见 `include/net/busy_poll.h:117`。主循环在 `net/core/dev.c:6809`，仍执行 NAPI 和内核协议栈，因此不是 kernel-bypass（绕过内核数据路径）。

接口和限制见 `Documentation/networking/napi.rst:255`：可按 socket 设置 `SO_BUSY_POLL`，也有全局 `net.core.busy_poll`/`busy_read`；6.18 另有 epoll/io_uring 接入。epoll 使用时需要同一 context 的 fd 具有同一 NAPI ID（该文档第 268 行）。应用分发连接和 B3 的 RSS/reuseport 规划需要配合。

`SO_PREFER_BUSY_POLL` 允许偏向持续轮询、抑制中断，但要求应用及时再次进入；定时器提供回退，见同文档第 311 行。不要把“配置了 socket 选项”当作所有流都永久无中断。

## 4. 演进

| commit / 作者 | 动机 | 性能数据 |
|---|---|---|
| `060212928670` / Eliezer Tamir | 加入最早 low latency socket poll 支撑，使 socket 路径主动轮询设备。协议支持由后续提交接入。 | 该提交未提供性能数据。 |
| `93d05d4a320c` / Eric Dumazet | 将 busy polling 支持推广到通用 NAPI 驱动，减少驱动专用接入协议。 | 该提交未提供性能数据。 |

历史 `ndo_ll_poll` 和旧 sysctl 名称不是 6.18 使用接口。收益幅度必须在具体硬件和负载测量，不能因为目标是低延迟就宣称始终更快。

## 5. 取舍

可减少中断/调度等待并改善局部性，但消耗空轮询 cycles，提高功耗，挤占同核工作；流量稀疏时浪费比例更高。混合事件模型保留通用性，也增加队列关联、预算和中断恢复配置。

## 6. 用户态对照

Seastar 固定提交 `e417c0c0...` 的 reactor 提供 `poll-mode`，明确选择持续轮询；主循环也有睡眠/空闲处理分支，不能把所有部署都说成永远满核。[固定 reactor.cc 第 3433、4033 行](https://github.com/scylladb/seastar/blob/e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b/src/core/reactor.cc#L3433)

## 7. 验证

隔离的目标 v6.18 环境使用支持选项的现有 RPC 程序，对比 busy-poll 关闭/开启；固定 CPU、RSS 与消息率，并测 p50/p99、CPU、空闲功耗和同核背景任务延迟。检查 NAPI ID 关联，先证明路径实际启用。未执行；仅测吞吐不能回答这个设计的主要问题。

## 要点回顾

- 应用等待时主动推进 NAPI，内核协议语义仍在。
- 收益依赖队列关联与负载。
- CPU、能耗和邻居延迟都是成本。

## 自测

1. busy poll 是否跳过 TCP 校验和状态机？
2. 同一 epoll context 的 NAPI ID 有何要求？
3. 为什么空闲流量也要测 CPU？

<details><summary>答案</summary>

1. 不跳过。2. 按本版本文档应一致。3. 为了计入空轮询成本，避免只看成功请求的延迟。

</details>

## 与 DPDK/VPP 的对照

熟悉的 PMD 轮询也是用 CPU 换等待时间，但内核 busy poll 保留 socket、权限和协议路径。两者共享性能动机，隔离边界与调用模型并不相同。
