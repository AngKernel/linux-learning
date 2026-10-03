# L04 参考推导：不提供 TCP 客户端实现

本篇回答：如何验算字段和关闭过程？前置：[L04 题面](../../L04-raw-tcp/)。预计阅读 15 分钟。

本目录仅包含推导与检查方法。先独立操作，再打开答案；完整 TCP 状态机、可执行握手客户端与重传代码按仓库约定不交付。整个 VM 实验【未实跑】，以下数值是**人为例题**，不是抓包结果。

<details><summary>字段与时间线参考</summary>

设 C=1000、S=9000，请求字节串 `GET / HTTP/1.0\r\nHost: lab\r\n\r\n` 的实际长度 G=29。

| 方向 | 内容 | seq | ack | 解释 |
|---|---|---:|---:|---|
| 客户→服务 | SYN | 1000 | 0（ACK 位无效） | 发完下一个 seq=1001 |
| 服务→客户 | SYN+ACK | 9000 | 1001 | 对端下一个 seq=9001 |
| 客户→服务 | ACK | 1001 | 9001 | 无 payload 不推进 seq |
| 客户→服务 | GET，G 字节 | 1001 | 9001 | 请求发完下一个 seq=1030 |
| 服务→客户 | 响应共 R 个连续字节 | 从 9001 起 | 常为 1030 | R 从抓包算，不是仅 HTTP body 长度 |
| 客户→服务 | 累计 ACK | 1030 | 9001+R | 前提是没有缺口 |
| 服务→客户 | FIN（可与末段数据合并） | 9001+R | 1030 | 控制位再消耗一个序号 |
| 客户→服务 | ACK，随后 FIN+ACK | 1030 | 9002+R | 纯 ACK 不消耗；FIN 消耗一个 |
| 服务→客户 | ACK | 9002+R | 1031 | 双向发送关闭完成 |

表只展示服务端先关闭的一种时序。响应分段、重复 ACK、FIN 合并均会改变包数。若服务先发 FIN，你的纸面状态依次经历 CLOSE_WAIT、LAST_ACK；如果自己先发 FIN，则需另外画主动关闭路径。FIN 的确认依赖前面所有数据连续收到。

IPv4 checksum：将 IP 头 checksum 清零，对 20 字节按网络字节序分成 16 位字求一补码和、回卷进位、取反。TCP checksum：清零字段后，对 IPv4 pseudo-header（src/dst、0、protocol=6、TCP 长度）、TCP header 与 payload 做同样计算。奇数末尾补零参与计算，不把补字节实际发送。IPv4 total length=20+20+payload；无 options 时 TCP data offset=5；window 32768 是练习值，不是实现了实际接收窗口管理。

kernel 仍按正常 TCP 处理输入：`net/ipv4/ip_input.c:193` raw 投递之后会继续协议分发；`net/ipv4/tcp_ipv4.c:2402` 在未找到 socket 时可发 RST。iptables 规则抑制该四元组的出站 RST，只是实验隔离措施。

</details>

<details><summary>四道思考题答案</summary>

1. 人工构包没有建立内核 TCP socket，内核查找失败后可能回应 reset。
2. SYN 和 FIN 各消耗一个序号；纯 ACK 不消耗。
3. 不可以。累计 ACK 表示下一个期待的连续字节位置，不能跳过缺口。
4. `ss` 查询内核 socket 状态，而人工连接状态在人的记录里；raw socket 本身不是那个 TCP socket。

</details>

验收失败时：没 SYN-ACK先看对端服务、目的 MAC/路由、checksum；出现 RST先看规则四元组与命中计数；有响应却一直重传则先检查 ACK 是否跨过缺口或漏计 FIN。原始 pcap、逐包字段表、工具版本与失败原因是最终证据。

要点回顾：报文与 socket 是两层；SYN/FIN 也占序号；ACK 只认连续字节；检查实际抓包。与 DPDK/VPP 对照：人工填包不等于构建协议状态机，发包 API 解决不了可靠性问题。
