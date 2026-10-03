# L07：XDP 计数、丢包与 iptables 对照

本篇回答：提前在驱动 RX 处理流量能省下哪些工作？如何避免把“发不出去”误当作高性能丢包？前置：[收发包路径](../../notes/02-datapath/rx-tx/)，完成 L02/L06。预计阅读 15 分钟，操作 2–3 小时。

目标：写一个 XDP（eXpress Data Path，快速数据路径）程序，仅对未分片 IPv4 UDP 目的端口 9000 计数或丢弃，并与 INPUT 规则对照。题面不提供实现；参考在 [solutions](../solutions/L07-xdp/)。BPF 对象静态编译可验证，guest verifier（验证器）、挂载和性能测试【未实跑】。

## 前置条件与步骤

1. VM1 的 virtio 实验接口为 `LAB_IF`；需要 clang 的 BPF target、iproute2 的 BPF 加载支持、bpftool、iperf3。先 `ip -details link show dev "$LAB_IF"`；已有 XDP 程序就用干净实验 VM，不覆盖别人的挂载。记录 `ethtool -l`、`ethtool -k`、MTU、vCPU 与 host 加速方式。
2. 自己在 `/tmp/l07` 编写 BPF C：对每次执行计数；先做 Ethernet/IPv4/UDP 边界检查；只处理无 VLAN、未分片 IPv4 UDP/9000；其他流量返回 PASS。用 per-CPU array（每 CPU 数组）分别统计总执行、匹配、丢弃。编译两个版本：只计数 PASS 与匹配后 DROP。不要对每个包打印日志。
3. 先在 VM1 运行 `iperf3 -s -B 192.0.2.11 -p 9000`。VM2 执行：

   ```bash
   iperf3 -c 192.0.2.11 -p 9000 -u -b 10M -l 512 -t 15
   ```

   TCP control 使用同端口但不同 protocol，不能被你的 UDP 条件丢掉。UDP 数据可能全丢，仍要记录**发送端实际发出速率**与服务器接收统计，不把零吞吐当作丢包 CPU 成本。
4. 按自己编译的对象加载 count 版本，明确选择 native（驱动原生）模式：

   ```bash
   sudo ip link set dev "$LAB_IF" xdpdrv obj /tmp/l07/count.o sec xdp
   ip -details link show dev "$LAB_IF"
   sudo bpftool prog show
   ```

   从该接口的 program ID 查到 map ID，测试前后分别 `sudo bpftool -p map dump id MAP_ID`，汇总各 CPU 数值的差。确认命中后卸载 count，再加载 drop。一次只装一个版本；native 不支持就记录错误，再用 `xdpgeneric` 重做功能实验，并明确其属于 skb 模式，不能填入 native 的性能列。
5. 至少做三轮：无 XDP/无规则；XDP count；XDP drop；然后卸载 XDP，单独添加对应 iptables 规则：

   ```bash
   sudo iptables -I INPUT 1 -i "$LAB_IF" -p udp --dport 9000 \
     -m comment --comment ll-l07 -j DROP
   sudo iptables -nvL INPUT --line-numbers
   ```

   所有轮次采用相同流量、包长、持续时间、队列与 CPU 条件，逐步升到 50M/100M，先确认发包端能够达到目标。每轮至少重复三次。CPU 可用 `mpstat -P ALL 1 15`（需 sysstat）；也记录 guest `/proc/softirqs` 前后差与宿主 QEMU CPU 开销。若 KVM/发包端/单队列已经瓶颈，就报告该瓶颈，不继续推出硬件极限。
6. tcpdump 只用来做低速功能定位，性能轮次停掉抓包和 tracing。比较 native XDP 丢弃与 INPUT 丢弃时 tcpdump 是否仍能看见流量；将 map/iptables 命中、发送端计数和应用收包三类证据并列。
7. 只撤销本实验对象：native 用 `sudo ip link set dev "$LAB_IF" xdpdrv off`，generic 用 `xdpgeneric off`；删除精确 INPUT 规则：

   ```bash
   sudo iptables -D INPUT -i "$LAB_IF" -p udp --dport 9000 \
     -m comment --comment ll-l07 -j DROP
   ```

   结束自己启动的 iperf3。确认接口上已无本次程序。

## 预期观察与验收

应能用同一流量比较 count 和 DROP；不匹配 SSH/ARP 应保持可用。验证器可能拒绝缺边界检查的程序，记录日志并修正。对照表至少含模式、实际 offered pps、matched/dropped、接收 pps、guest/host CPU、重复轮次；本文不给性能倍数与实测数字。native XDP 可避免后续 skb/协议处理，但具体节省量须实测。

源码锚点：`drivers/net/virtio_net.c:1804` 对 XDP action 的处理、`:1840` 的 DROP、`:6042` 的配置入口；`include/uapi/linux/bpf.h:6515` 的 action，`:6524` 的 `xdp_md`，`:987` 的 PERCPU_ARRAY。是否能加载 native XDP 是运行时事实，不仅由函数存在决定。

## 要点回顾

- 首先证明匹配条件正确，再测成本。
- native 与 generic 是两种路径，应分列。
- 同一 offered rate、包长、CPU 条件才有比较意义。
- 丢包实验中接收吞吐为零不是性能结论。

## 思考题与分层提示

1. 为什么要保留 ARP 和 iperf3 的 TCP control？
2. 为什么 map 的“总执行次数”可能大于 iperf3 包数？
3. XDP drop 后 tcpdump 没有包，怎样证明发包端实际发了？
4. 同样都能丢包，generic 与 native 为什么要分开列？

<details><summary>提示一：控制变量</summary>先把实验控制连接、ARP 和待测 UDP 数据分开，检查每层独立计数。</details>
<details><summary>提示二：证据</summary>画出发包端、virtio/XDP、packet tap、netfilter、应用五处位置；表中每个数字注明采样点。</details>

## 与 DPDK/VPP 的对照

XDP 程序像 RX graph 前部的短小节点；仍运行在内核驱动路径，需通过 verifier 和 helper 约束。它既不是完整 VPP graph，也不等于用户态忙轮询 PMD；本例 per-CPU map 与 worker 私有计数有相似目的。
