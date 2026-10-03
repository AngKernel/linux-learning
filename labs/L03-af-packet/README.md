# L03：用 AF_PACKET 抓包

本篇回答：用户态怎样取得 Ethernet 帧？抓包副本出现在哪一层？前置阅读：[总览](../../notes/01-overview/)、[收发包路径](../../notes/02-datapath/rx-tx/)，完成 L01。预计阅读 10 分钟，操作 60–90 分钟。

目标：自己写一个 C 抓包程序，与 tcpdump 按 MAC、EtherType、长度、方向核对。本文是题面，参考代码与答案在 [solutions](../solutions/L03-af-packet/)。所有 VM 操作【未实跑】，环境约定见 [实验入口](../README.md)。

## 前置条件与步骤

1. 在 VM1 设置 `LAB_IF=lab0`（quick 模式按实验 MAC 找接口），记录 `ip -br link`、`ethtool -k "$LAB_IF"`。不要在 `any` 上做 Ethernet 首部逐字节对照，因为其 link type 可不同。
2. 在 `/tmp/l03` 写程序：用 `socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL))` 创建 socket；用 `if_nametoindex` 和 `sockaddr_ll` 绑定接口；循环 `recvfrom`；打印收到的长度、`sll_pkttype`、前 64 字节十六进制。检查参数、短帧、系统调用返回值，Ctrl-C 后退出。无需实现 TCP、IP 重组或 libpcap。
3. `cc -std=c11 -Wall -Wextra -Werror -O2 /tmp/l03/capture.c -o /tmp/l03/capture`，以 root 运行。同时在另一终端：

   ```bash
   sudo tcpdump -ni "$LAB_IF" -e -xx -c 12 'arp or icmp'
   ```

   从 VM2 执行 `ping -c 3 192.0.2.11`。自己的程序未安装过滤器，先按 EtherType 找相同帧，不把其所有行数与 tcpdump 过滤后的行数相比。
4. 再由 VM1 ping VM2，记录本机发出帧的 `sll_pkttype`。改变 `recvfrom` 缓冲区大小到 32，记录截断后长度；不要把它当作原始线上长度。
5. 清理只需结束两个进程、删除 `/tmp/l03`。提交自己的观察表：方向、抓包时间、MAC、EtherType、长度、对应 ICMP id/seq。原始 pcap 留树外。

## 预期观察与验收

接收与发送帧都可能出现在 AF_PACKET；Ethernet 首部包含在 SOCK_RAW 数据中。是否含 VLAN tag、报文长度及 checksum 显示会受 offload 和抓包位置影响。先以无 VLAN 的小 ICMP 帧验收，不能要求所有发送 checksum 都已在抓包副本中完成。验收是至少逐字节对齐一组请求/回复，并解释计数差异，不是达到指定条数。

源码起点（全部 v6.18）：`include/uapi/linux/if_packet.h:14` 的 `sockaddr_ll`；`:30` 的 `PACKET_OUTGOING`；`include/uapi/linux/if_ether.h:132` 的 `ETH_P_ALL`；`net/packet/af_packet.c:343` 注册 packet tap，`:2114` 普通接收回调，`:2227` packet mmap 回调。tcpdump 使用哪个接收 API 取决于 libpcap，不能仅凭程序名断言一定走后者。

## 要点回顾

- 抓包副本、协议栈的接收权与网卡队列所有权是不同概念。
- 先限定接口、方向和流量，再比较两个工具。
- 解析前检查长度，保存 offload 条件。

## 思考题与分层提示

1. 为什么开两个抓包程序通常不会各自分走一半包？
2. SOCK_RAW 的前两个字节为什么不一定是 IPv4 版本字段？
3. 为什么 tcpdump 与你的程序总行数不同？
4. 抓到一个包能否证明 TCP 已接受它？

<details><summary>提示一：方向</summary>区分 tap 的副本与协议分发；对照程序是否都使用相同过滤器。</details>
<details><summary>提示二：定位</summary>检查 AF_PACKET 注册位置及 L2 首部长度；分别记录接收和发送方向、缓冲区大小与 offload 状态。</details>

## 与 DPDK/VPP 的对照

AF_PACKET 可类比一个镜像输出接口；通常不会像 PMD 的 RX burst 那样直接取得硬件队列 buffer 的独占处理权。普通 `recvfrom` 也不是 mbuf pool 的零拷贝收包。先完成题面，再看参考答案。
