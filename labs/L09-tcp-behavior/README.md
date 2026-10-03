# L09：比较 TCP 拥塞控制、延迟与丢包

本篇回答：怎样确认一条新连接使用 CUBIC 或 BBR？延迟、随机丢包怎样影响 cwnd、RTT 和重传？一次吞吐结果能支持多强的结论？前置：[TCP 可靠性与性能](../../notes/02-datapath/tcp/04-reliability-and-performance.md)、[连接生命周期](../../notes/02-datapath/tcp/03-connection-lifecycle.md)，完成 L02。预计阅读 15 分钟，操作 60–90 分钟。

目标：形成两算法 × 两种网络条件的观察表。本文只有题面；[参考脚本与推导](../solutions/L09-tcp-behavior/) 应在写下自己的预测后阅读。**所有 VM 命令和行为预期【未实跑】**；没有实测吞吐排名。

## 前置条件与实验设计

按 [env](../../env/README.md) 启动两台专用 6.18 VM，`/work` 为共享仓库。VM1 `192.0.2.11` 是**数据发送方**，VM2 `192.0.2.12` 是接收方；cloud 的数据 NIC 为 `lab0`。需要 iperf3、iproute2（tc/ss）、sudo；P3 配置要求 CUBIC、BBR、FQ、NETEM，但必须检查最终运行内核。

本实验改变 VM1 的系统默认算法与数据 NIC 的 root qdisc（根排队规则）。从**新启动、没有自定义 qdisc 的专用 VM1**开始，先显式建立本实验拥有的 `fq` 基线。若接口已有需保留的自定义队列规则，另开实验 VM；`tc -j` 只是记录，不能当作通用恢复脚本。

VM1：

```bash
uname -r
LAB_IF=lab0                         # quick 模式按 .11 对应接口修改
mkdir -p /tmp/l09
ip route get 192.0.2.12
sysctl net.ipv4.tcp_available_congestion_control
sysctl -n net.ipv4.tcp_congestion_control > /tmp/l09/original-cc.txt
tc -s qdisc show dev "$LAB_IF" > /tmp/l09/original-qdisc.txt
ethtool -k "$LAB_IF" > /tmp/l09/offloads.txt
sudo tc qdisc replace dev "$LAB_IF" root handle 109: fq
tc -s qdisc show dev "$LAB_IF"
```

`ip route get` 的 dev 必须是数据 NIC，不能选 cloud 下载网卡。算法列表应包含 `cubic bbr`；缺项先检查 P3 配置/模块，不把修改 sysctl 失败当成已启用。若编为模块，可按 env 的匹配模块说明加载；不要使用宿主 6.8 的模块。

两种条件是：

| 条件 | root qdisc | 用途 |
|---|---|---|
| `clear` | `fq`，handle `109:` | 不注入网络故障的基线 |
| `netem` | `netem delay 20ms loss 0.5% limit 10000`，handle `209:` | 单方向延迟与随机丢包，结束恢复 `fq` |

两条件的 qdisc 也不同，不能把 clear→netem 的全部差异都归因于丢包率。算法间比较应在**相同条件**进行。BBR 在 root netem 下走 TCP 内部 pacing（定速发送）兜底；这里没有声称 netem 内同时存在 fq。若要单独区分延迟与丢包，可按同一恢复规则增加 delay-only 与 loss-only 轮次，统一记录条件。

## 操作步骤

1. VM2 启动专用服务端并保持前台运行，最终 Ctrl-C：

   ```bash
   iperf3 -s -B 192.0.2.12 -p 5229
   ```

2. VM1 逐轮执行，**每轮结束后再开始下一轮**：

   ```bash
   sudo bash /work/labs/solutions/L09-tcp-behavior/run-round.sh "$LAB_IF" cubic clear 30 /tmp/l09/cubic-clear
   sudo bash /work/labs/solutions/L09-tcp-behavior/run-round.sh "$LAB_IF" bbr clear 30 /tmp/l09/bbr-clear
   sudo bash /work/labs/solutions/L09-tcp-behavior/run-round.sh "$LAB_IF" cubic netem 30 /tmp/l09/cubic-netem
   sudo bash /work/labs/solutions/L09-tcp-behavior/run-round.sh "$LAB_IF" bbr netem 30 /tmp/l09/bbr-netem
   ```

   helper 先检查接口、算法和实验拥有的 fq 基线，保存当前默认算法，再设置新算法、创建新连接。它每约 0.5 秒采样一次 `ss -tin`，流量目标固定为 50 Mbit/s，保存 iperf3 与 qdisc 计数，最后恢复进入本轮前的算法和 handle `109:` 的 fq。随机丢失的短轮次不保证必出现重传；需要时延长所有轮次，不能只挑异常最明显的一轮。

3. 阅读每轮目录下的 `ss.txt`、`iperf.txt`、`qdisc-after.txt` 与 `restored.txt`。脚本使用的核心命令如下，可对照理解：

   ```bash
   sysctl -w net.ipv4.tcp_congestion_control=bbr
   tc qdisc replace dev "$LAB_IF" root handle 209: netem delay 20ms loss 0.5% limit 10000
   ss -tin '( sport = :5229 or dport = :5229 )'
   tc -s qdisc show dev "$LAB_IF"
   ```

   这些核心命令由 helper 在受控保存/恢复范围内执行，**不要额外在另一个终端重复修改参数**。端口还包含 iperf 控制连接，按有持续大量字节传输的四元组识别数据流，不能将所有 `ss` 行视为同一条连接。

4. 建立观察表，至少记录：算法实际名称、数据流四元组、目标/实测速率、cwnd、RTT、重传相关字段原始输出、qdisc 丢弃数、采样窗口。记录 3 次重复轮次的变化范围；同一算法应每次建立新连接。不要把 `ss` 的当前在途重传与累计重传字段混为一项，也不要把 tc 丢弃数与 TCP 重传数强行对应。

5. 结束后确认 helper 已恢复，并恢复实验前默认算法：

   ```bash
   sudo sysctl -w "net.ipv4.tcp_congestion_control=$(cat /tmp/l09/original-cc.txt)"
   tc -s qdisc show dev "$LAB_IF"      # 本实验基线应为 fq 109:
   ```

   若中断后 root 仍是 netem，手工执行 `sudo tc qdisc replace dev "$LAB_IF" root handle 109: fq` 再读回。这个恢复目标是实验建立的 fq 基线，不是任意原始自定义 qdisc。全部结束后可在宿主用 `env/down.sh 1` 再用相同模式 `env/up.sh cloud 1`（quick 则改为 quick）重启专用 VM，还原未持久化的网卡队列配置。VM2 的本实验服务用 Ctrl-C 退出；不要按名称杀掉其他 iperf 服务。

## 预期观察与验收

【未实跑的预期】新数据连接在 `ss -ti` 中显示所选算法；增加单方向 20 ms 延迟可能使 RTT 增加约 20 ms，而不是自动增加 40 ms。接收端仍有 ACK 延迟、排队、调度等影响，因此不要求数值精确相等。随机丢包可能触发重传，算法窗口与定速行为可能不同；0.5% 不是保证每 200 个线上 TCP 段恰丢 1 个。

本拓扑没有专门设置固定速率的链路瓶颈，且 QEMU、GSO/TSO、采样开销与应用发流上限都影响吞吐。验收是正确识别算法、控制条件并解释证据范围，不能输出“BBR 永远更快”等结论。`ss` 是快照，短暂状态可漏采；L10 再用事件时间线补充。

源码依据均为 v6.18：

- `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/sysctl_net_ipv4.c:964` 与 `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/sysctl_net_ipv4.c:971`：默认算法与已注册算法查询。
- `/home/chen/code/linux-lab/src/linux-6.18/Documentation/networking/ip-sysctl.rst:412`：默认算法影响新连接，被动连接继承 listener。这里只比较 VM1 主动发送，若做反向测试必须重新定义发送方。
- `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp_cubic.c:478` 与 `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp_bbr.c:1143`：算法注册；`/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp_bbr.c:55`：无 fq 时内部 pacing 兜底。
- `/home/chen/code/linux-lab/src/linux-6.18/net/sched/sch_netem.c:1012`：参数处理；`/home/chen/code/linux-lab/src/linux-6.18/net/sched/sch_netem.c:1061`：limit/latency/loss 赋值。
- `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp.c:4196`、`/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp.c:4255`、`/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp.c:4263`：TCP_INFO 的 cwnd、RTT、累计重传数据源。工具展示单位与内核内部单位应分别核对。

## 要点回顾

- 在发送方设置算法，重新建流并用 ss 验证。
- 切 root netem 会替换 root fq；明确每轮的实际 qdisc。
- 相同条件比较算法，多次重复观察随机波动。
- 记录四元组，区分数据流与控制流。
- 参数恢复也是实验验收的一部分。

## 思考题与分层提示

1. 已建立的长连接为什么不能仅凭 sysctl 新值判断算法已切换？
2. VM1 的 egress（出口）增加 20 ms，为什么不能直接预测 RTT 增加 40 ms？
3. 先设置 root fq，再设置 root netem，怎样确认最终规则？
4. tc 丢弃 10 个 skb，为什么 TCP 累计重传不必恰好增加 10？
5. 两算法都达到 50 Mbit/s 时，能否认为它们有相同的拥塞行为？

<details><summary>提示一：方向</summary>区分连接创建时配置、单方向路径、qdisc 树、统计单位与应用提供的负载。</details>
<details><summary>提示二：定位</summary>查看默认算法的作用范围、`tc -s qdisc` 实际树和每个数据流的 ss 原始字段；检查 offload 与重复轮次。</details>

## 与 DPDK/VPP 的对照

`netem` 可类比一个有延迟队列和随机丢弃的测试节点，cwnd 则是协议端点的发送约束，不能把两者都当成网卡 TX ring 深度。DPDK 测试中常固定 burst/绑核与发包速率；这里还需记录内核 pacing、qdisc、offload 和 VM 调度。未确认项为 guest 实跑、参数支持、采样有效性和全部性能数值。
