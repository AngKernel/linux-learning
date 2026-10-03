# L02：观察 NAPI 的批量处理与预算

本篇回答：一次 NAPI poll（轮询）做了多少工作？`netdev_budget` 与单次 poll 的 budget 是什么关系？virtio 的中断合并参数是否真的可调？前置：[执行上下文](../../notes/00-kernel-basics/01-execution-context.md)、[接收路径](../../notes/02-datapath/rx-tx/01-receive-path.md)，完成 L01。预计阅读 12 分钟，操作 60–90 分钟。

目标：在固定流量条件下比较 CPU 分布、softirq（软中断）次数/时间和 NAPI 工作量。本目录只有题面；先完成观察表，再读 [脚本及参考答案](../solutions/L02-napi/)。**全部 VM 运行、参数修改和预期现象【未实跑】**；脚本只经过静态检查。

## 前置条件

沿用 [env](../../env/README.md) 两台 6.18 VM。VM1 `.11` 收流，VM2 `.12` 发流，仓库位于 `/work`；cloud 使用 `lab0`，quick 按实验地址寻找接口。需要 bpftrace ≥ 0.21、iperf3、ethtool、sudo。只在专用实验 VM 调参。

VM1 记录初始状态：

```bash
uname -r
LAB_IF=lab0                         # quick 模式按实际值修改
mkdir -p /tmp/l02
ip -br address > /tmp/l02/address.txt
ethtool -i "$LAB_IF" > /tmp/l02/driver.txt
ethtool -k "$LAB_IF" > /tmp/l02/offloads.txt
sudo ethtool -c "$LAB_IF" > /tmp/l02/coalesce-before.txt 2>&1
sysctl net.core.netdev_budget net.core.netdev_budget_usecs
cat /proc/interrupts > /tmp/l02/interrupts-before.txt
cat /proc/softirqs > /tmp/l02/softirqs-before.txt
```

`ethtool -c` 失败也是应保存的能力结果。不要因此放弃后续 budget 实验。记录 vCPU 数、网卡队列数、GRO 状态，保持各轮一致；一条流并不保证分布到所有 CPU。

## 步骤一：先核实 tracepoint

VM1：

```bash
sudo mountpoint -q /sys/kernel/tracing || sudo mount -t tracefs tracefs /sys/kernel/tracing
sudo bpftrace -lv 'tracepoint:napi:napi_poll'
sudo bpftrace -lv 'tracepoint:irq:softirq_entry'
sudo bpftrace -lv 'tracepoint:irq:softirq_exit'
```

应看到 NAPI 的 `napi`、`dev_name`、`work`、`budget`，softirq 的 `vec`。字段缺失时记录运行内核与配置，停止挂载脚本；不能用旧版结构体偏移补猜字段。`napi_poll` 发生在回调返回之后，不能单凭该事件计算回调耗时。

## 步骤二：固定负载，比较三轮预算

在 VM1 独立终端启动实验专用服务，结束时 Ctrl-C：

```bash
iperf3 -s -B 192.0.2.11 -p 5222
```

VM1 的追踪终端分别执行以下各轮，**一轮完全结束后再执行下一轮**：

```bash
sudo bash /work/labs/solutions/L02-napi/budget-round.sh 300 25 > /tmp/l02/budget-300.txt
# 下一轮
sudo bash /work/labs/solutions/L02-napi/budget-round.sh 64 25 > /tmp/l02/budget-64.txt
# 再下一轮
sudo bash /work/labs/solutions/L02-napi/budget-round.sh 600 25 > /tmp/l02/budget-600.txt
```

每轮在 VM1 的 `/tmp/l02/budget-*.txt` 看到 `READY` 后，VM2 发同样的流量：

```bash
iperf3 -c 192.0.2.11 -p 5222 -t 20 -P 4 -b 20M
```

这是 4 个并行流、每流目标 20 Mbit/s；实际吞吐以输出为准。低负载可能看不出预算差异，先保留这组结果，再有控制地提高速率并把三轮全部重做；不要只提高某一组流量。脚本每轮保存并恢复原 `netdev_budget`，退出时输出恢复结果。它不改 `netdev_budget_usecs` 或 IRQ affinity。

读取各文件中的 `@rx_calls`、`@rx_us`、`@poll_work`、`@poll_budget`、`@at_budget`，按 CPU、设备和 NAPI 指针归组。同设备可能有多个 RX/TX NAPI 实例，不把它们混成一个直方图。实验结束再拍快照：

```bash
cat /proc/softirqs > /tmp/l02/softirqs-after.txt
cat /proc/interrupts > /tmp/l02/interrupts-after.txt
sysctl net.core.netdev_budget net.core.netdev_budget_usecs
```

## 步骤三：有条件地比较中断合并

先检查 `coalesce-before.txt`。若 `ethtool -c` 不支持，或 adaptive-rx 开启且尚未设计自适应参数的恢复方案，标为“本环境未做固定 usecs 对照”，保留步骤二。若当前 `rx-usecs` 是可读的整数且 adaptive-rx 关闭，在 VM1 **单独执行下面整个子 shell**；它只修改这一项并用 trap 恢复：

```bash
(
  set -e
  OLD_RX=$(sudo ethtool -c "$LAB_IF" | awk '$1 == "rx-usecs:" {print $2; exit}')
  [[ $OLD_RX =~ ^[0-9]+$ ]] || { echo '无法保存原 rx-usecs，跳过该分支'; exit 3; }
  if ! sudo ethtool -C "$LAB_IF" rx-usecs 20; then
    echo '设备拒绝修改；记录错误，继续使用 budget 实验结果'
    exit 3
  fi
  trap 'sudo ethtool -C "$LAB_IF" rx-usecs "$OLD_RX"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  sudo ethtool -c "$LAB_IF" | tee /tmp/l02/coalesce-during.txt
  sudo bpftrace -B line /work/labs/solutions/L02-napi/napi.bt 25 > /tmp/l02/coalesce-20us.txt
)
sudo ethtool -c "$LAB_IF" > /tmp/l02/coalesce-after.txt 2>&1
```

在 `READY` 后由 VM2 发相同负载。检查读回值确为目标值；命令成功但读回不符时，本轮不能算参数对照成功。退出后核对 `rx-usecs` 已恢复；失败则用保存值手动执行 `sudo ethtool -C "$LAB_IF" rx-usecs 原值`，确认后再做下一实验。

## 预期观察与验收

【未实跑的预期】能得到每 CPU 的 NET_RX 软中断次数/包围时间，以及每 NAPI 的 work、budget 分布。增大 `netdev_budget` 不承诺改变单次 poll 的 `budget`，也不承诺把工作迁移到另一 CPU。负载、队列、IRQ affinity、RPS、时间预算都影响结果。softirq 时间包括其同步子调用和可能的硬中断干扰，不是每包 CPU 时间。

virtio 未协商相应通知合并特性时，非零 usecs 可能返回 `Operation not supported`；这就是本设备能力边界，并非实验失败。验收表必须包含参数“请求值/读回值/恢复值”、实际流量、CPU 与 NAPI 分组指标、以及没有变化的结果。至少保留预算三轮；中断合并分支可明确“不支持”。

源码依据均为 v6.18：

- `/home/chen/code/linux-lab/src/linux-6.18/include/trace/events/napi.h:14`：NAPI 字段；`/home/chen/code/linux-lab/src/linux-6.18/include/trace/events/irq.h:103`：softirq 的 `vec` 字段。
- `/home/chen/code/linux-lab/src/linux-6.18/include/linux/interrupt.h:549`：枚举从 HI=0 开始，NET_RX 为 3。
- `/home/chen/code/linux-lab/src/linux-6.18/net/core/dev.c:7580`：poll 使用实例 weight；`/home/chen/code/linux-lab/src/linux-6.18/net/core/dev.c:7745`：一轮接收软中断使用总预算和时间预算。
- `/home/chen/code/linux-lab/src/linux-6.18/net/core/sysctl_net_core.c:554`：`netdev_budget` 注册；`/home/chen/code/linux-lab/src/linux-6.18/net/core/sysctl_net_core.c:577`：`netdev_budget_usecs` 注册。
- `/home/chen/code/linux-lab/src/linux-6.18/drivers/net/virtio_net.c:5398`：没有相应特性时的 coalescing 参数限制；`/home/chen/code/linux-lab/src/linux-6.18/drivers/net/virtio_net.c:5425`：设置分支。

## 要点回顾

- 修改前保存、修改后读回、退出后确认恢复。
- 区分软中断总预算与单 NAPI 权重。
- 按 CPU、设备、实例分组，保留 work=0 的情况。
- IRQ 次数、poll 次数和 work 不是同一种计数。
- 不支持 coalescing 时仍可完成预算实验。

## 思考题与分层提示

1. 为什么将 `netdev_budget` 从 300 改为 600，事件中的 budget 可能不变？
2. 同时看到许多 work=0 与较大的 RX work，应先怎样拆分数据？
3. 四条流仍主要落在一个 CPU，能否仅靠增加预算解决？
4. `rx-usecs 20` 被拒绝时，你能提交哪些有效实验结果？

<details><summary>提示一：方向</summary>先找三个层次：CPU 的软中断循环、NAPI 实例、驱动队列。</details>
<details><summary>提示二：定位</summary>比较 `__napi_poll` 传入的 weight 与 `net_rx_action` 扣减的变量；查看设备特性检查，并保留读回和恢复记录。</details>

## 与 DPDK/VPP 的对照

NAPI poll 可类比有限额的 RX burst，但 NET_RX 软中断还要在多个实例间安排工作；它不是固定绑核的 PMD 无限轮询循环。调总预算类似改变一次调度能处理的工作量，不能直接类比改变 RSS 或 worker 绑定。清理时退出本实验的 iperf3 服务；日志留 `/tmp/l02`。guest 挂载、参数支持与性能效果仍待实跑。
