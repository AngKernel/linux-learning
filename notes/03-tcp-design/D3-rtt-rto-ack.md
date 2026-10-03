# D3. RTT、RTO 与 ACK：反馈越及时，代价也越高

本篇回答：为何 RTO 不能等于最近一次 RTT？delayed ACK 与 quick ACK 如何折中？前置阅读：D1、D2、ACK 与重传。预计阅读：11 分钟。源码基准：Linux v6.18。

## 1. 问题

过短的重传超时会把调度抖动当丢包；过长又让真丢包恢复很慢。每包立即 ACK 提供快速反馈，却消耗反向带宽与双方 CPU；过度延后又可能拖慢短请求或触发伪重传。

## 2. 约束

路径 RTT 跨越数量级，ACK 可能聚集，接收应用可慢读，拥塞与丢包也会变化。重传后测量可能有歧义，因此不能把每个 ACK 到达时间都直接当新样本。RTO 也不是所有丢包恢复机制的唯一时钟。

## 3. 方案

`tcp_rtt_estimator()` 保存平滑 RTT 和偏差，见 `net/ipv4/tcp_input.c:1037`。`srtt_us` 是微秒值乘 8 的定点表示，不是直接可显示的 RTT；更新约为旧值 7/8 加新样本 1/8。偏差下降/上升路径并非完全对称，并按轮次维护 `mdev_max_us/rttvar_us`，避免过快缩小超时。

`__tcp_set_rto()` 使用 `(srtt_us >> 3) + rttvar_us` 并转为 jiffies，见 `include/net/tcp.h:834`。`rttvar_us` 已含实现所用的偏差尺度，不能再机械乘 4。这里描述的是核心估计；最终还受最小值、上限和重传退避影响。

ACK 策略保存在 `icsk_ack`。`tcp_in_quickack_mode()` 查看快速 ACK 预算和交互模式（`net/ipv4/tcp_input.c:336`），普通快速 ACK 预算会消耗。`TCP_QUICKACK` 处理见 `net/ipv4/tcp.c:3653`，不能理解成一次设置后永久每包 ACK 的保证。

`tcp_send_delayed_ack()` 根据当前 ACK 间隔、RTT 和最大值计算到期，已有更早定时器不会随每个包无限向后推，见 `net/ipv4/tcp_output.c:4364`。`tcp_delack_max()` 还结合 RTO 最小值（第 4353 行），避免允许的 ACK 延时比期望的重传底线还大。D1 的 compressed ACK 是另一条优化路径。

## 4. 演进

| commit / 作者 | 动机 | 正文数据 |
|---|---|---|
| `740b0f1841f6` / Eric Dumazet | RTT 估计改成微秒分辨率，适应数据中心与 pacing；保留旧指标 ABI 兼容。 | 示例 10G 链路 SRTT 32 μs；这是可观测精度示例，该提交未提供性能收益数据。 |
| `bbf80d713fe7` / Eric Dumazet | delayed ACK 上限跟随 RTO 最小值，避免只下调 RTO 却未下调 ACK 等待。 | 示例 route RTO min 5 ms 后 ACK 上限 4 ms；未给吞吐/延迟性能对比。 |

早期 Jacobson 估计的出处在代码注释中，但本篇未访问该论文原文，不把注释中的论文引用扩展为已阅读的外部证据。

## 5. 取舍

平滑提高稳健性，也降低跟随突变的速度；快速 ACK 消耗资源，延迟 ACK 节省包数但增加反馈等待。短 RTT 场景中，应用调度和本机排队可比线路传播更大；降低 RTO 前应先确定噪声来源。

## 6. 用户态对照

Seastar native TCP 固定提交 `e417c0c0...` 的 `update_rto()` 使用毫秒样本与 RFC6298 式平滑，限制在 1–60 秒；见 `include/seastar/net/tcp.hh:2022`。这里仅陈述该版本实现，不代表所有用户态栈或其 POSIX 后端。[固定源码](https://github.com/scylladb/seastar/blob/e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b/include/seastar/net/tcp.hh#L2022)

## 7. 验证

目标环境用受控延迟/丢包链路跑已有 TCP 程序，观察 `ss -ti` 的 rtt/rto 与抓包 ACK 间隔；分别做稳定延迟、突增延迟、少量丢包。抓包需记录 GRO/TSO 状态，不能拿 ACK 聚集简单推算应用读取时间。本实验未运行。

## 要点回顾

- 估计值、定点单位和 timer 单位必须分开。
- quick ACK 是动态策略，不是永远开启的保证。
- ACK 等待与 RTO 调整需要协调。

## 自测

1. `srtt_us=800` 是否表示 RTT 800 μs？
2. 最近 RTT=1 ms 就把 RTO 设 1 ms 合理吗？
3. 为什么延迟 ACK 不能无限被新包后推？

<details><summary>答案</summary>

1. 不是，平滑 RTT 为 100 μs。2. 不合理，需考虑波动、底线与调度。3. 会阻断反馈并可能引发重传，源码保留更早到期。

</details>

## 与 DPDK/VPP 的对照

稳定轮询可能降低主机噪声，但不能消除网络排队、对端调度和重传歧义。自建用户态 TCP 仍需平滑、偏差和 ACK 策略；仅有高精度时间戳不等于估计正确。
