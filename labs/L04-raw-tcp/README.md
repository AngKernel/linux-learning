# L04：用 raw socket 手工驱动一次 TCP 连接

本篇回答：怎样手工填写 TCP 序号、发 HTTP GET 并有序关闭？为什么内核会干扰这条连接？前置：[TCP 机制](../../notes/02-datapath/tcp/)，完成 L03；熟悉网络字节序和一补码 checksum。预计阅读 20 分钟，操作 2–3 小时。

目标是在隔离 VM1→VM2 路径上，用现成 raw socket 工具逐包注入**自己手工填写的字节**，抓包验证握手、请求、响应和关闭。遵守仓库约定：本实验不提供自动握手客户端、TCP 状态机、重传队列或用户态 TCP 栈代码。字段推导与校验方法在 [solutions](../solutions/L04-raw-tcp/)。操作【未实跑】。

## 前置条件与准备

VM1 为 `192.0.2.11:40000`，VM2 为 `192.0.2.12:8080`；端口 40000 须未被 socket 占用。VM1 需 socat、xxd、iptables、tcpdump；这些是额外依赖，`env/` 未保证装有 socat/xxd。VM2 使用内核 TCP 提供普通 HTTP 服务：

```bash
mkdir -p /tmp/l04-www
printf 'ok\n' > /tmp/l04-www/index.html
python3 -m http.server 8080 --bind 192.0.2.12 --directory /tmp/l04-www
```

VM1 先在 `ss -tan` 中检查端口，再启动 `sudo tcpdump -ni "$LAB_IF" -s0 -S -vv -XX 'tcp and host 192.0.2.12 and port 8080'`；也可以独立保存 `/tmp/l04.pcap`。`-S` 使 TCP seq/ack 采用绝对值。不要同时启用 L07 的丢弃程序。

## 操作步骤

1. 先不添加 RST 规则。选一个 ISN（初始序号）C，在纸面/表格填写完整 IPv4+TCP SYN：IPv4 IHL=5、TTL=64、protocol=6、源/目的地址如上、不分片；TCP source=40000、dest=8080、seq=C、ack=0、data offset=5、flags=SYN、window=32768、无 options、无 payload。计算两个 checksum。把自己算出的连续 hex 保存 `/tmp/l04-syn.hex`，转成二进制后注入一个包：

   ```bash
   xxd -r -p /tmp/l04-syn.hex > /tmp/l04-syn.ip
   wc -c /tmp/l04-syn.ip
   sudo socat -u OPEN:/tmp/l04-syn.ip,rdonly IP4-SENDTO:192.0.2.12:255
   ```

   本实验每个文件仅含一个长度小于 MTU 的完整 IPv4 数据报；以上命令不负责 TCP 构包、checksum、状态和重传。socat 的 `IP4-SENDTO` 使用 raw IP socket，protocol 255 允许数据中包含 IP 头；依据实际访问的 [socat 手册](https://man7.org/linux/man-pages/man1/socat.1.html)。记录对端 SYN-ACK 后是否紧跟本机 RST。
2. 在 VM1 增加仅覆盖本次四元组的规则：

   ```bash
   sudo iptables -I OUTPUT 1 -o "$LAB_IF" -p tcp \
     -s 192.0.2.11 --sport 40000 -d 192.0.2.12 --dport 8080 \
     --tcp-flags RST RST -m comment --comment ll-l04 -j DROP
   sudo iptables -nvL OUTPUT --line-numbers
   ```

   换一个 C 重新开始；如果上次四元组仍有残余状态，等待回收或换未占用源端口，并同步修改规则。后续每一步保存自己的 header 表、hex 与抓包。规则只丢 RST，不丢手工 SYN/ACK/FIN。
3. 注入新 SYN，捕获对端 ISN=S。根据抓包填写第二个文件完成第三次握手 ACK；**先自行推导 seq/ack**。用同一 socat 单包命令发送新的文件。不要猜对端序号。
4. 手工构造一个 PSH+ACK 或 ACK 携带 `GET / HTTP/1.0\r\nHost: lab\r\n\r\n`，这里 `\r\n` 指真实的 `0d 0a` 字节。TCP checksum 覆盖 pseudo-header、TCP header 与 payload。逐次注入、等待抓包，不把多包拼到一个 raw datagram 文件。
5. 按响应的 seq 与 payload 长度维护纸面的“最高连续收到字节位置”，给出累计 ACK。可能分多个段，也可能发生重复；先收齐缺口再推进 ACK。HTTP 服务可能主动 FIN，把 FIN 与数据是否同段一并记下。手工 ACK 对端 FIN，并用自己的 FIN+ACK 关闭发送方向，等待其 ACK；也允许双方 FIN 同时到达，但要按实际抓包推导。本实验没有自动重传，超时失败就记录原因并重做，不将一次成功宣称可靠 TCP 实现。
6. 完成后检查 VM2 `ss -tan '( sport = :8080 )'`，记录尾部 ACK 和 FIN 的方向；等待对端不再重传后删除且只删除本实验规则：

   ```bash
   sudo iptables -D OUTPUT -o "$LAB_IF" -p tcp \
     -s 192.0.2.11 --sport 40000 -d 192.0.2.12 --dport 8080 \
     --tcp-flags RST RST -m comment --comment ll-l04 -j DROP
   ```

   结束自己启动的 HTTP 服务。手工 raw 流在 VM1 不会成为普通 TCP socket，不能要求 `ss` 显示它的 ESTABLISHED/TIME_WAIT。

## 预期观察与验收

交付抓包时间线和字段表：SYN、SYN-ACK、ACK、GET、响应、FIN/ACK。验收时逐行核对 seq、ack、payload 长度、SYN/FIN 消耗，不给定固定包数；响应可分段，ACK 可合并。另提交“无规则/有规则”的 RST 对照与规则计数。不要把本机 TX offload 的 checksum 显示当作对端已验证，必要时看 VM2 抓包。

源码锚点：`net/ipv4/raw.c:482` 的发送入口；`net/ipv4/ip_input.c:193` 先给 raw socket 投递，并不因此屏蔽正常协议处理；`net/ipv4/tcp_ipv4.c:2387` 的无 TCP socket 分支，`:2402` 发送 reset。TCP 报文仍进入内核 TCP，因此仅“开 raw socket”不能独占该四元组。

## 要点回顾

- raw socket 提供注入/观察入口，不替你维护 TCP 状态。
- 每次推进序号前先数清连续字节与控制位。
- 本实验只处理人工驱动的单连接和可解释失败，不实现可靠协议栈。

## 思考题与分层提示

1. 收到 SYN-ACK 时，为什么内核 TCP 可能发 RST？
2. SYN、FIN 与纯 ACK 分别怎样影响序号空间？
3. 如果先收到后一段响应，可以把 ACK 直接移到该段末尾吗？
4. 为什么 VM1 的 `ss` 看不到这条手工连接？

<details><summary>提示一：查证</summary>把“IP 协议分发”和“TCP socket 查找”画成两步，区分 raw socket 与 TCP socket。</details>
<details><summary>提示二：推导</summary>表格中分别维护两个方向的下一个字节编号；使用抓包中的实际长度，重复段不能重复加长度。</details>

## 与 DPDK/VPP 的对照

像用 mbuf 手工填协议头，但此处路由和真实 NIC TX 仍归内核。丢 RST 只是避免本机内核状态与人工连接冲突，不会替你实现重传、流量控制或拥塞控制。
