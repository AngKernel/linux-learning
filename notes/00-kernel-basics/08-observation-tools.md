# 08 调试与观测：先明确测到了哪一层

本篇回答：从接口计数到函数执行该用什么工具？每个工具的输出证明什么？怎样用短时跟踪确认网络代码？
前置阅读：[01 执行上下文](01-execution-context.md)、[06 阅读方法](06-reading-kernel-code.md)。预计阅读时间：18 分钟。
源码基准：Linux v6.18。工具示例面向实验 VM；本次宿主为 6.8，以下运行时实验均未在 v6.18 VM 实跑，不提供伪造的测量结果。

## 运行前提

在实验 VM 安装 iproute2、ethtool、perf、bpftrace；ftrace（内核内建跟踪）通过 tracefs 文件系统使用。本篇 bpftrace 脚本按 0.24 语法写，先用 `bpftrace --version` 核对。Shell 命令按 bash 执行。

用 `uname -r` 确认运行内核；源码 tag 不等于当前运行内核。先从 `ip -br link` 找接口，再设置 `IFACE=eth0`，将 eth0 改成实际实验网卡。跟踪期间从另一终端制造实验流量；回环可以观测 socket/IP 活动，物理驱动、硬件 IRQ、RSS 则需要相应设备。

CONFIG_FUNCTION_TRACER、CONFIG_BPF_SYSCALL、CONFIG_KPROBES、CONFIG_PERF_EVENTS 的定义分别见 `kernel/trace/Kconfig:225`、`kernel/bpf/Kconfig:27`、`arch/Kconfig:117`、`init/Kconfig:2020`。这些只是相关配置入口，不是完整依赖清单。实际可用性还受构建、挂载与权限影响。若 `/sys/kernel/tracing/instances` 不存在，先按环境篇准备 tracefs；不要把空事件列表当成“网络没有执行”。

## printk / dmesg：看明确发生过的日志

printk（内核日志输出）家族用于记录事件，dmesg 读取环形日志缓冲区。真实网络例子是 e1000 的 `pr_info` 驱动日志，见 `drivers/net/ethernet/intel/e1000/e1000_main.c:220`，链路状态输出见同文件 `:2450`。

```sh
sudo dmesg -T | rg -i 'e1000|virtio_net|link.*(up|down)|NETDEV'
sudo dmesg -w
```

第一条查看已有事件，第二条持续跟随，Ctrl-C 结束。没有日志不代表没有包；热路径也不能靠逐包打印来测性能。`-T` 的墙钟显示仅方便阅读，不用来做精确延迟分析。

## /proc/net 与 /sys/class/net：读取系统导出的状态

procfs 与 sysfs 是内核生成内容的接口。网络代码注册 `/proc/net/dev` 与 `softnet_stat` 的位置见 `net/core/net-procfs.c:311`；接口状态和统计目录在 `net/core/net-sysfs.c:457`、`:893`。

```sh
cat /proc/net/dev
cat /proc/net/softnet_stat
cat /sys/class/net/"$IFACE"/operstate /sys/class/net/"$IFACE"/mtu /sys/class/net/"$IFACE"/statistics/rx_packets
```

`dev` 给接口计数，`softnet_stat` 是按 CPU 的软件网络统计，最后一条读取指定接口。不要凭其他版本的博客硬编码 softnet_stat 列号；需对照 v6.18 的输出实现。比较流量前后增量比看累计大数字更有意义。`/proc/net` 与网络命名空间有关；比较前确认命令处于同一个实验 namespace。

## ss：看 socket 与 TCP 状态

ss 属于 iproute2，适合查看 socket 状态、队列和 TCP 信息。内核诊断路径可从 `net/ipv4/inet_diag.c:804` 的 dump 分派开始读；它不同于直接读取物理网卡统计。

```sh
ss -lnt
ss -tin
ss -tmn
```

依次查看监听 TCP socket、连接内部信息、socket 内存信息。`-n` 避免名称解析。Listen 的队列语义与已建立连接不同；输出的队列值也不能统一当作网卡 descriptor 数量。此处参数已用本机 ss 帮助核对，具体输出字段随版本和连接状态不同。

## ethtool：先认驱动，再看它的统计

驱动实现自己的统计集合。例如 e1000 操作表含：

```c
.get_ethtool_stats = e1000_get_ethtool_stats,
```

出处：`drivers/net/ethernet/intel/e1000/e1000_ethtool.c:1881`；取值函数见同文件 `:1807`。

```sh
ethtool -i "$IFACE"
ethtool -S "$IFACE"
ethtool -k "$IFACE"
```

分别识别驱动、读取驱动统计、查看 offload（硬件/软件卸载）开关。字段名和含义由驱动决定；不要把所有设备的 `rx_dropped` 一概解释为同一个阶段。若 veth/loopback 缺少某项，不是工具坏了。这里都是读取，不改变实验条件。

## ftrace：短时确认 ops 的目标执行过

网络目标 `inet_recvmsg` 的定义在 `net/ipv4/af_inet.c:875`，表赋值在同文件 `:1071`。先做两次发现：

```sh
sudo cat /sys/kernel/tracing/available_filter_functions | rg '^inet_recvmsg([[:space:]]|$)'
sudo cat /sys/kernel/tracing/available_events | rg '^(napi:|net:)'
```

第三个命令组创建独立 instance，跟踪 5 秒，并清理自己创建的 instance。在另一终端运行已有实验程序，触发 IPv4 socket 接收；不限制应用 PID，以免今后复用时漏掉由其他上下文执行的工作。

```sh
sudo sh <<'SH'
set -eu
trace_root=/sys/kernel/tracing
trace_instance="$trace_root/instances/p2-basics-$$"
test -d "$trace_root/instances"
mkdir "$trace_instance"
cleanup() {
    echo 0 > "$trace_instance/tracing_on"
    echo nop > "$trace_instance/current_tracer"
    rmdir "$trace_instance"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo 0 > "$trace_instance/tracing_on"
echo inet_recvmsg > "$trace_instance/set_ftrace_filter"
echo function > "$trace_instance/current_tracer"
echo 1 > "$trace_instance/tracing_on"
sleep 5
echo 0 > "$trace_instance/tracing_on"
cat "$trace_instance/trace"
SH
```

ftrace 文件的含义见 `Documentation/trace/ftrace.rst:259`，instance 删除示例见 `:3730`。命中说明函数实际执行；普通 function tracer 不提供完整参数语义，也不能从同名函数出现次数推导网线上包数。缓冲区容量和跟踪开销同样影响结果。

## bpftrace：按 CPU 汇总 NAPI 工作

先列事件，再看参数，再短时统计，三条命令分别回答“有吗”“长什么样”“实际发生多少”：

```sh
sudo bpftrace -l 'tracepoint:napi:*'
sudo bpftrace -lv 'tracepoint:napi:napi_poll'
sudo bpftrace -e 'tracepoint:napi:napi_poll { @polls[cpu] = count(); @work[cpu] = sum(args.work); } interval:s:5 { exit(); }'
```

事件及 work 字段在 `include/trace/events/napi.h:14`、`:23`；网络执行处调用 `trace_napi_poll(n, work, weight)`，见 `net/core/dev.c:7595`。work 是此处回调报告的工作量，不能一概替代硬件 RX 包数；多个 NAPI、回调实现、聚合与预算语义会影响解释。

本例 `args.work` 采用 bpftrace 0.24 文档中的字段语法，见[官方语言说明](https://bpftrace.org/docs/release_024/language)。旧版本应核对本机帮助和版本文档，不在没有解析通过时声称已得到测量结果。[06](06-reading-kernel-code.md) 还给出了不读取参数的 inet_recvmsg kprobe 计数。

## perf：计数与采样回答不同问题

perf 通过内核性能事件设施工作；先确认事件，再做短时计数和调用栈采样。

```sh
perf list 'net:*'
sudo perf stat -a -e net:net_dev_queue,net:netif_receive_skb -- sleep 5
sudo perf record -a -g -e net:net_dev_queue -o /tmp/p2-net.perf.data -- sleep 5
```

第三条会创建 `/tmp/p2-net.perf.data`；之后用 `sudo perf report --stdio -i /tmp/p2-net.perf.data` 阅读并自行保留或删除。它跟踪已选网络事件的调用栈；不是 CPU 热点采样。样本数量受事件频率、缓冲区和丢失记录影响。

网络代码中这两处事件发射分别在 `net/core/dev.c:4727`、`:5863`；事件格式在 `include/trace/events/net.h:144`、`:151`。它们表示特定软件位置，**不保证每条收包路径都命中同一个 receive 事件，也不等于线速包数**。参数帮助已核对本机 perf 文档，v6.18 VM 的采集尚未执行。

## 动手：三种计数为什么不相等

在同一个 5 秒实验窗口，分别保存接口计数增量、NAPI work 汇总和一个 tracepoint 的命中次数。先记接口、namespace、流量方向和 offload，再解释差异。不要预设三个数字应该相等；若要验证逐包对应，必须沿被选路径核对事件放置和聚合边界。

## 要点回顾

- 日志、接口计数、socket 状态和函数事件分别属于不同层。
- 先发现事件/函数，再采集；没有命中不是路径不存在的充分证据。
- NAPI work 与软件事件数不能统一等同硬件包数。
- 用短时独立跟踪会话，记录版本、接口与实验条件。
- 静态源码核对与运行时测量分别报告，不能混写。

## 自测

1. dmesg 没有收包日志，能说明没有流量吗？
2. perf stat 的 netif_receive_skb 计数一定等于 NIC rx_packets 吗？
3. 用 PID 过滤网络接收观察为什么可能漏事件？
4. 拿本地 v6.18 源码，能直接把宿主的跟踪结果称为 v6.18 行为吗？

<details><summary>答案</summary>

1. 不能，正常热路径通常不会逐包输出日志。
2. 不能，二者在不同层，路径覆盖与聚合方式也不同。
3. 相关工作可能在软中断或其他线程上下文执行，当前 PID 不等于应用 PID。
4. 不能，必须确认实际运行版本、配置和符号匹配。

</details>

## 与 DPDK/VPP 的对照

ethtool 统计类似驱动/端口统计，ss 类似观察协议端点，ftrace/BPF 类似在具体处理节点观察执行，perf 帮助统计或采样。这些对应只用于选工具；内核多个上下文与多层聚合使单一应用 PID、单一队列、单一“包数”的假设更容易失效。
