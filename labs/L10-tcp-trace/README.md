# L10：用 tracepoint 记录 TCP 状态与重传

本篇回答：一次连接实际产生哪些状态事件？怎样将重传关联到连接？为什么一个 socket 指针不能表示连接生命周期的全部内核对象？前置：[连接生命周期](../../notes/02-datapath/tcp/03-connection-lifecycle.md)、[可靠性与性能](../../notes/02-datapath/tcp/04-reliability-and-performance.md)，完成 L09。预计阅读 15 分钟，操作 60–90 分钟。

目标：从实际输出绘制一条连接的状态时间线，并明确半连接、TIME_WAIT 与重传事件的观测边界。本目录只有题面；[参考脚本与推导](../solutions/L10-tcp-trace/) 包括观察器和使用内核 socket 的小应用，**没有用户态 TCP 协议栈实现**。全部 VM 执行、BPF 挂载及预期现象【未实跑】。

## 前置条件与事件发现

沿用 [env](../../env/README.md)：VM1 `192.0.2.11` 主动连接 VM2 `192.0.2.12`，仓库在 `/work`；cloud 数据 NIC 是 `lab0`。需要两台 6.18 VM、bpftrace ≥ 0.21、Python 3、ss；重传轮次另需 L09 的 iperf3、netem 条件。先在 VM1：

```bash
uname -r
mkdir -p /tmp/l10
sudo mountpoint -q /sys/kernel/tracing || sudo mount -t tracefs tracefs /sys/kernel/tracing
sudo bpftrace -lv 'tracepoint:sock:inet_sock_set_state'
sudo bpftrace -lv 'tracepoint:tcp:tcp_retransmit_skb'
sudo bpftrace -lv 'tracepoint:tcp:tcp_retransmit_synack'
```

必须核对这些字段，而不是从旧博客复制偏移：

| 事件 | 本实验使用的字段 | 边界 |
|---|---|---|
| `sock:inet_sock_set_state` | skaddr、oldstate、newstate、family、protocol、sport、dport、saddr、daddr | 不是所有 socket 类对象的所有状态写入都经过这里 |
| `tcp:tcp_retransmit_skb` | skaddr、state、family、sport、dport、saddr、daddr、err | 没有 protocol、seq、rto 字段；事件也可能报告失败尝试 |
| `tcp:tcp_retransmit_synack` | skaddr、req、family、sport、dport、saddr、daddr | 单独的 SYN-ACK 事件，没有 err/state 字段 |

本实验主脚本只挂前两种。第三种用于选做 SYN-ACK 观察，缺失时不要随意用普通重传事件代替。端口字段已转换成主机字节序，按十进制端口直接比较。

## 步骤一：记录单连接的建立与主动关闭

1. VM2 先运行一次性服务端；它收到客户端 EOF 后延迟约 1 秒再发送短回复、关闭写方向：

   ```bash
   python3 -u /work/labs/solutions/L10-tcp-trace/one-connection.py server 192.0.2.12 5230
   ```

   看到 `READY` 后保持终端等待。这是普通 socket 应用，只用内核 TCP；它不手工构造 TCP 首部。

2. VM1 终端 A 启动追踪并保存文件；看到文件里的 `READY` 后再建连接：

   ```bash
   sudo bpftrace -B line /work/labs/solutions/L10-tcp-trace/tcp-events.bt 5230 40 > /tmp/l10/state-events.txt
   ```

   在 VM1 另一个终端可用 `tail /tmp/l10/state-events.txt` 查看准备状态，然后：

   ```bash
   python3 -u /work/labs/solutions/L10-tcp-trace/one-connection.py client 192.0.2.12 5230
   ss -tan state time-wait > /tmp/l10/timewait.txt
   ```

   记录客户端输出的本地地址/临时端口。程序先 `shutdown(SHUT_WR)`，再读到服务端 EOF；这让主动关闭角色明确。server 每次只处理一条连接，重试前需要重启 server。

3. 追踪窗口结束后，在 VM1 处理日志：

   ```bash
   awk '$1 ~ /^[0-9]+$/ {print}' /tmp/l10/state-events.txt | sort -n -k1,1 > /tmp/l10/state-sorted.txt
   cat /tmp/l10/state-sorted.txt
   cat /tmp/l10/timewait.txt
   ```

   按本地/远端地址、端口、`skaddr` 与本次连接起止范围识别一条流。CPU 不同可能使输出消费顺序不同，先按记录的 `nsecs` 排序；同时间值不代表严格的因果先后。`skaddr` 是对象地址，释放后可复用，不是永久连接 ID。

4. **画两层记录。** 上层只画实际 `STATE` 行的 old→new，标明相对首事件的时间和 CPU；下层列出 `ss` 的 TIME_WAIT 快照以及不能由主脚本直接覆盖的阶段。可用以下 Mermaid 模板自行替换，不预填教材状态：

   ```mermaid
   sequenceDiagram
       participant O as 观测记录
       participant S as 本次完整 socket
       participant W as TIME_WAIT 快照
       O->>S: t1 实际 oldstate → newstate
       O->>S: t2 实际 oldstate → newstate
       O-->>W: 另行记录 ss 中同一四元组
   ```

   VM2 可另外运行同一 tracepoint 脚本观察服务端，但两台 VM 的单调时钟原点不同，**不要直接将两机 nsecs 相减**。监听 socket、request_sock（半连接请求对象）、已接受子 socket、TIME_WAIT 对象也不能按一个指针拼成统一生命周期。

## 步骤二：在持续流中观察重传

第一轮短连接没有重传也正常。复用 L09 的受控 netem 轮次，以持续数据流增加可观察机会：

- VM2 新开终端：`iperf3 -s -B 192.0.2.12 -p 5229`。
- VM1 数据 NIC 应仍为 L09 明确建立的 `fq 109:` 基线；先 `tc -s qdisc show dev lab0` 检查。quick 替换实际接口名；若不是该基线，按 L09 的专用 VM 前置步骤建立，不能覆盖其他自定义规则。
- VM1 终端 A 先启动观察，等 `READY`：

  ```bash
  sudo bpftrace -B line /work/labs/solutions/L10-tcp-trace/tcp-events.bt 5229 45 > /tmp/l10/retrans-events.txt
  ```

- VM1 终端 B 再运行（输出目录必须未存在）：

  ```bash
  LAB_IF=lab0
  sudo bash /work/labs/solutions/L09-tcp-behavior/run-round.sh "$LAB_IF" cubic netem 30 /tmp/l10/retrans-round
  ```

按 ss 数据连接的四元组区分 iperf 控制与数据连接，结合 `RETRANS` 行的 `err`、qdisc 计数和 ss 原始字段记录重传尝试。若没有事件，先检查探针、窗口、数据流与 qdisc 确实生效，再记录本次无事件；随机 loss 不保证固定次数。不要把所有重传都标为 RTO（重传超时）触发，主事件没有提供此原因。

选做：在 VM2 挂独立 `tcp:tcp_retransmit_synack`，过滤 `sport == 5229` 并打印 `skaddr`、`req` 和四元组。只在实际捕获到时增加 SYN-ACK 记录；正常数据重传实验未必影响握手，不能伪造该事件。

## 预期观察、验收与清理

【未实跑的预期】在 VM1 看到主动连接的若干建立、关闭状态事件；时间线可能没有 `newstate=TIME_WAIT`，而 ss 仍显示相同四元组的 TIME_WAIT。实验验收不是凑齐教材所有状态，而是解释对象和探测边界。普通重传事件中的 `err != 0` 表示尝试失败；`err == 0` 仍不证明对端收到。

提交自己的状态事件表、Mermaid 时间线、TIME_WAIT 快照和重传统计口径；明确哪些是观测、哪些是源码推导。数值映射位于 `/home/chen/code/linux-lab/src/linux-6.18/include/net/tcp_states.h:12`；不要把 TCP 状态与拥塞控制的 recovery 等状态混在一张枚举表里。

结束观察器或等其定时退出；一次性 Python 应用会自行关闭 socket，VM2 的 iperf 服务用 Ctrl-C 结束。L09 helper 负责恢复参数，再检查 `/tmp/l10/retrans-round/restored.txt` 和 `tc -s qdisc`。无需清除系统 TIME_WAIT 表，它应按正常协议机制退出。所有证据留 `/tmp/l10`，不提交运行产物。

源码定位均为 v6.18：

- `/home/chen/code/linux-lab/src/linux-6.18/include/trace/events/sock.h:140`：状态事件字段及端口赋值。
- `/home/chen/code/linux-lab/src/linux-6.18/include/trace/events/tcp.h:16`：普通重传字段；`/home/chen/code/linux-lab/src/linux-6.18/include/trace/events/tcp.h:289`：SYN-ACK 重传字段。
- `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp_output.c:3625`：普通重传尝试的事件调用点。
- `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/inet_connection_sock.c:938`：request_sock 状态初始化；`/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/inet_connection_sock.c:1271`：完整子 socket 的状态设置。
- `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp_minisocks.c:328`：TIME_WAIT 对象交接；`/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/tcp.c:4987`：旧完整 socket 的结束处理。

## 要点回顾

- 先用 `-lv` 核对真实事件和字段。
- 用四元组、对象与窗口共同关联，不用 PID 替代连接身份。
- 记录事件时间，区分单机排序与跨机时钟。
- 半连接和 TIME_WAIT 存在主 tracepoint 覆盖不到的阶段。
- 重传尝试、发送成功和对端收到是不同证据。

## 思考题与分层提示

1. tracepoint 最后是 CLOSE，而 ss 还有 TIME_WAIT，能否判定工具相互矛盾？
2. 服务端的 SYN-ACK 重传中，`skaddr` 一定是后来 accepted socket 吗？
3. 为什么不能对普通重传事件访问 `args.protocol` 或 `args.rto`？
4. 为什么同一个 PID 过滤器可能漏掉连接的大量状态/重传事件？
5. 如何区分“没有重传”“观察窗口没覆盖”“探针不可用”？

<details><summary>提示一：方向</summary>分别考虑对象种类、事件声明、执行上下文和观察窗口。</details>
<details><summary>提示二：定位</summary>沿 request_sock 初始化、TIME_WAIT 分配与 tcp_done 查状态写入，再对照每个 TRACE_EVENT 的字段及调用点。</details>

## 与 DPDK/VPP 的对照

你可把一次 tracepoint 当作协议状态机埋点，但 `skaddr` 不是贯穿所有阶段的应用连接句柄。DPDK/VPP 的 worker 线程 ID 常便于定位归属；内核事件可能在软中断或不同任务上下文发生，当前 PID/comm 不等于 socket 的拥有者。未确认项：guest 挂载、实际输出、一次性应用交互以及重传概率；本章没有提供伪造的实测时间线。
