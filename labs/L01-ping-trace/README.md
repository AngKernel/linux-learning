# L01：跟踪一次 ping 的接收与回复

本篇回答：ICMP 请求怎样从 virtio 网卡进入 IPv4？回复怎样进入发送路径？为什么一组函数计数不是一条包的完整时间线？前置阅读：[执行上下文](../../notes/00-kernel-basics/01-execution-context.md)、[接收路径](../../notes/02-datapath/rx-tx/01-receive-path.md)、[发送路径](../../notes/02-datapath/rx-tx/02-transmit-path.md)。预计阅读 12 分钟，操作 45–60 分钟。

目标：将抓包中的一次 Echo Request/Reply 与内核路径证据对应，解释观察工具的边界。本目录只有题面；先完成记录，再读 [参考答案及追踪脚本](../solutions/L01-ping-trace/)。**以下 VM 命令、探针挂载和预期结果均【未实跑】**；源码已按 v6.18 核对，运行环境尚待验收。

## 前置条件

按 [env](../../env/README.md) 启动两台 Linux 6.18 VM，仓库挂在 `/work`。VM1 为 `192.0.2.11`，VM2 为 `192.0.2.12`。本实验在 VM1 追踪，由 VM2 发 ping，避免 loopback 绕过 virtio。cloud 模式的数据接口是 `lab0`；quick 模式以 `ip -br address` 中 `.11` 对应接口为准。需要 root、tcpdump、bpftrace ≥ 0.21 和 function_graph（函数调用图）支持。

在 VM1：

```bash
uname -r                       # 必须是本实验的 6.18 内核
ip -br address
LAB_IF=lab0                    # quick 模式按实际接口修改
ethtool -i "$LAB_IF"            # 记录 driver，预期为 virtio_net
mkdir -p /tmp/l01
sudo mountpoint -q /sys/kernel/tracing || sudo mount -t tracefs tracefs /sys/kernel/tracing
bpftrace --version
```

`uname -r` 只验证运行版本；宿主源码还应执行 `git -C /home/chen/code/linux-lab/src/linux-6.18 describe --always --dirty --tags` 并记录 `v6.18`。

## 操作步骤

1. **先发现探测点。** 在 VM1 执行；任一名称缺失时记录缺项，不把缺项计为零次调用。

   ```bash
   for fn in virtnet_poll gro_receive_skb ip_rcv ip_list_rcv ip_local_deliver icmp_rcv ip_local_out __dev_queue_xmit; do
     sudo bpftrace -l "kprobe:$fn"
   done
   sudo awk '$1 == "net_rx_action" || $1 == "icmp_rcv" {print}' /sys/kernel/tracing/available_filter_functions
   ```

   脚本要求上列 kprobe 均可见；否则先检查内核配置、编译优化和驱动是否加载。不要为了让脚本通过而静默删除探针。

2. **先抓包，再发一组低速 ping。** 在 VM1 终端 A：

   ```bash
   sudo timeout --signal=INT 20 tcpdump -ni "$LAB_IF" -w /tmp/l01/ping.pcap 'icmp and host 192.0.2.12'
   ```

   在 VM1 终端 B，运行提供的观察脚本，等 `READY`：

   ```bash
   sudo bpftrace -B line /work/labs/solutions/L01-ping-trace/ping-path.bt 15 > /tmp/l01/events.txt
   ```

   再在 VM2：

   ```bash
   ping -n -c 3 -i 1 192.0.2.11
   ```

   VM1 脚本 15 秒后退出；`READY` 已写入重定向文件，可从另一终端用 `tail /tmp/l01/events.txt` 查看。tcpdump 到时退出的状态码可能是 timeout 的 124，需检查文件而非把它当成捕获失败。

3. **另开一轮 function_graph。** 不把两轮时间戳当成同一次 ping。VM1 运行：

   ```bash
   sudo bash /work/traces/function-graph.sh net_rx_action 15 24 > /tmp/l01/rx.graph 2> /tmp/l01/rx.stats
   ```

   VM2 再发相同的 3 次 ping。检查 graph 中的嵌套调用以及统计中的 overrun。如果入口不存在，按步骤 1 核实后用 `icmp_rcv` 作较小的 graph 根；记录此时没有观察网卡到 ICMP 之前的部分。P3 工具使用独立 tracefs instance 并在退出时清理。

4. **匹配证据，而非拼接假链路。** VM1 阅读捕获：

   ```bash
   sudo tcpdump -nn -tt -r /tmp/l01/ping.pcap
   less /tmp/l01/events.txt
   less /tmp/l01/rx.graph
   cat /tmp/l01/rx.stats
   ```

   自己建立表：ICMP id/seq、请求/回复方向、两个 IPv4 入口各是否出现、ICMP 阶段、发送阶段、未覆盖的异步边界。bpftrace 使用单调时钟纳秒，tcpdump 通常显示墙钟；不要直接相减。脚本不解析 ICMP id/seq，端口上的 SSH/其他包也会触发通用函数，因此只能与受控时间窗及 graph 合并形成路径证据。

## 预期观察与验收

【未实跑的预期】请求与回复在 pcap 中可按 ICMP id/seq 匹配；`icmp_rcv` 与 IPv4 输出阶段有事件；IPv4 分发可能主要经过 `ip_list_rcv`。函数调用数不必与 ping 数相等。function_graph 展示一个根函数的同步调用子树，GRO 批处理、后续软中断或 qdisc 调度可能越过这棵树。

验收提交一张自己的路径图（Mermaid）、一组 pcap 摘要、探针发现结果与 graph 丢记录统计。图上区分“实际观察到”“源码连接关系”“本轮未覆盖”；不得把 `ip_rcv` 无事件单独判为 IPv4 未工作，也不得把 `__dev_queue_xmit` 到达解释为对端已收到。

## 源码定位与清理

以下完整路径均基于 v6.18：

- `/home/chen/code/linux-lab/src/linux-6.18/drivers/net/virtio_net.c:3114`：`virtnet_poll`；`/home/chen/code/linux-lab/src/linux-6.18/drivers/net/virtio_net.c:2610` 将 skb 交给 GRO。
- `/home/chen/code/linux-lab/src/linux-6.18/include/linux/netdevice.h:4190`：`napi_gro_receive` 是 inline 包装；实际探测候选为 `/home/chen/code/linux-lab/src/linux-6.18/net/core/gro.c:624` 的 `gro_receive_skb`。
- `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/af_inet.c:1879`：单包与 list 两种 IPv4 入口注册。
- `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/icmp.c:1019`：Echo 处理；`/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/icmp.c:369`：构造回复并提交 IP 输出。
- `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/ip_output.c:1519`：`ip_push_pending_frames`；`/home/chen/code/linux-lab/src/linux-6.18/net/core/dev.c:4670`：`__dev_queue_xmit`。

本实验不改网络参数。等待观察程序退出或 Ctrl-C；P3 graph 工具会清理自己的 instance，bpftrace 退出卸载自己的探针。保留证据于 `/tmp/l01`，不把 pcap 提交到仓库。动态挂载、具体 graph 深度与无丢记录窗口尚未确认。

## 要点回顾

- 用另一台 VM 发送请求，确认实际走实验 virtio NIC。
- 源码中存在函数、目标机可挂载、运行时触发是三项检查。
- 记录单包和 list 两个 IPv4 入口。
- 抓包关联用 ICMP id/seq；通用函数日志仅提供阶段证据。
- 明确同步 graph 与异步排队的边界。

## 思考题与分层提示

1. pcap 有回复，而 `ip_rcv` 没出现，应先查看什么证据？
2. 为什么不能按 VM2 的 ping PID 过滤 VM1 的整个接收路径？
3. 能否用同一个 skb 指针串起请求接收和回复发送？
4. graph 中没有某个子函数，能否证明它没有执行？

<details><summary>提示一：方向</summary>分别检查入口选择、执行上下文、对象生命周期和观察器覆盖范围。</details>
<details><summary>提示二：定位</summary>阅读 IPv4 packet_type 注册、GRO_NORMAL 的去向、ICMP 回复构造代码，再核对 available_filter_functions 与 overrun。</details>

## 与 DPDK/VPP 的对照

将 `virtnet_poll` 类比一次 RX burst，将 graph 类比 VPP 节点 trace；但内核会在 IRQ、softirq 与其他执行上下文之间交接，graph 并非完整的异步 packet trace。skb 也不保证像你自己维护的 mbuf 指针那样贯穿整条请求/响应路径。
