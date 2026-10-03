# L09 参考推导

本篇回答：怎样从受控轮次解释 TCP 观察结果？前置：[L09 题面](../../L09-tcp-behavior/)。预计阅读 10 分钟。文件包括本答案与 `run-round.sh`；先做预测和观察表，再读推导，最后检查脚本保存/恢复逻辑。脚本静态检查不代表 guest 已验证，所有 VM 结果【未实跑】。

`tcp_congestion_control` 是新连接的默认选择；被动连接继承 listener。依据 `/home/chen/code/linux-lab/src/linux-6.18/Documentation/networking/ip-sysctl.rst:412`，切换后应建立新的主动发送连接，并从其 ss 输出核实算法。脚本的 VM1 是唯一被比较的数据发送方；VM2 的 ACK 方向不因此自动变成同一套受控实验。

netem 是出口排队处理，本例 VM1→VM2 数据方向加了 20 ms，反向 ACK 未加相同延迟。RTT 的变化还叠加排队、ACK 策略与调度；这支持“单方向配置”的解释，不支持用一次快照算精确传播时延。

BBR 的实现明确说明无 fq 时会使用每 socket 的内部高精度计时器 pacing，见 `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp_bbr.c:55`。因此不能照搬较旧配置帮助文字，写成“没有 fq 就绝对不能运行”。但这两种 pacing 条件也不能说成完全等价。题面把 root fq 与 root netem 分成两组，root 修改不会自动保留前一个规则作为子 qdisc。

<details><summary>五道思考题答案</summary>

1. sysctl 是默认选择，已有 socket 有自己的拥塞控制状态；检查数据四元组的实际算法，或重新建流。服务端发数据时还需考虑旧 listener 的继承关系。
2. 本例只在 VM1 出口延迟数据；ACK 的反向出口没有配置同样延迟。约 +20 ms 是本设置的直观预测，实测还受其他延迟影响。
3. 用 `tc -s qdisc show dev 接口` 检查；连续两次 root replace 后只留下后一个 root，不是自动叠加。
4. qdisc 处理 skb，GSO 可能让一个 skb 对应多个线上段；控制连接、ACK 丢失、后续重复丢失与 TCP 恢复都会改变计数关系。应记录统计口径而非强行一一相等。
5. 不能。50 Mbit/s 是应用提供负载的目标；都达到上限仍可能有不同 cwnd、RTT、排队和重传。未触及某种瓶颈时吞吐尤其缺少区分度。

</details>

恢复说明：helper 只接受预先创建的 `fq 109:`，进入 netem 后退出恢复同一实验基线，并恢复进入本轮前的默认算法。它不承诺恢复任意自定义 qdisc。输出目录必须尚不存在，防止轮次相互覆盖；失败时保留原始数据和 restored.txt，供手动检查。

要点回顾：默认与实例分开；方向明确；qdisc 树读回；重复轮次；不从应用限速推导算法上限。与 DPDK/VPP 对照：人为 impairment 类似测试节点，发送端拥塞控制是有历史状态的反馈算法，不能只看瞬时 burst 计数。未确认项包括 guest 执行、ss 用户态版本的具体字段展示和任何吞吐/时延数值。
