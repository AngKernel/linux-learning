任务：编写 labs/，一组循序渐进的动手实验，配合 notes/ 中的学习内容。每个实验一个目录，README.md 包括：目标、对应的笔记章节、前置条件、操作步骤、预期观察到的现象、思考题、提示（分层给出，先给方向再给细节）。参考答案统一放在 labs/solutions/ 对应的目录里，README 中不要出现答案。
所有实验都要能在 env/ 搭建的 QEMU 虚拟机中完成（env/ 可能由另一个任务同时编写，按 virtme-ng 或 QEMU + virtio_net 的通用环境来写即可）；涉及的探测点、tracepoint、sysctl 必须先在 v6.18 中确认存在。

实验列表：
L01 跟踪一次 ping：用 ftrace function_graph 和 bpftrace 观察 ICMP 包从网卡到回复发出的完整路径
L02 观察 NAPI：调整中断合并参数（ethtool -C）和 netdev_budget，观察软中断的 CPU 分布、每次 poll 处理的包数如何变化
L03 写一个 AF_PACKET 抓包程序（C 语言），与 tcpdump 的输出对比，理解它在路径上的哪个位置拿到包
L04 用 raw socket 手工完成 TCP 三次握手并发出一个 HTTP GET 请求，收到响应后正确关闭连接。说明为什么需要用 iptables 丢弃内核自动发出的 RST。这是迈向用户态 TCP 栈的第一步
L05 TUN 设备：用户态程序从 TUN 读写 IP 包，手工响应 ping
L06 写一个 netfilter 内核模块：在指定 hook 上统计并丢弃特定流量；对比挂在不同 hook 上的效果
L07 XDP：在驱动层计数并丢弃特定流量，与 iptables 丢包对比性能（用 pktgen 或 iperf3 产生流量）
L08 AF_XDP：把包直接收到用户态，这是将来用户态 TCP 栈的一种收包入口；与 L05 的 TUN 方式对比延迟和吞吐
L09 TCP 行为观察：切换拥塞控制算法（cubic/bbr），用 tc netem 注入丢包和延迟，用 ss -ti 观察 cwnd、rtt、重传等指标的变化
L10 用 bpftrace 跟踪 TCP 状态迁移和重传事件（优先使用 tracepoint），画出一次连接完整的状态变化时间线

最后在 labs/README.md 中给出：实验与笔记章节的对应表、建议的完成顺序、每个实验的预计耗时。
