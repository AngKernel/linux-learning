# L03 参考答案

本篇回答：怎样实现最小抓包循环、怎样解释副本与计数差异？前置：[L03 题面](../../L03-af-packet/)。预计阅读 10 分钟。

文件：`capture.c` 是原创的 AF_PACKET 普通 socket 示例。先做题，再读代码，再运行下面命令；不包含 promiscuous、BPF 过滤器、packet mmap 或协议解析。已通过宿主 GCC 严格编译；VM 收发【未实跑】。

```bash
cc -std=c11 -Wall -Wextra -Werror -O2 /work/labs/solutions/L03-af-packet/capture.c -o /tmp/l03-capture
sudo /tmp/l03-capture "$LAB_IF"
```

先校验 interface index，再绑定协议与接口，接收时打印 `sockaddr_ll` 元数据。这里显示的 IN 表示“不是 PACKET_OUTGOING”，不能进一步断言必为单播发往本机。`net/packet/af_packet.c:2114` 是普通 socket 的接收处理；不同 tap 各自接收副本，用户读取不会替协议栈消费同一 socket 队列。

<details><summary>四道思考题答案</summary>

1. 一般 tap 独立收副本。PACKET_FANOUT 是另一个主动配置的分流机制，本例没用。
2. SOCK_RAW 保留链路层头；本实验 Ethernet 帧开头是目的 MAC。
3. 对比过滤器、开始/结束时间、发送副本、缓冲区截断、工具自身丢包、offload，不能只看行数。
4. 不能。之后可能因 checksum、防火墙、socket 查找或序号校验等被丢弃。

</details>

要点回顾：绑定接口；长度优先；元数据区分方向；逐包匹配而非总数强行相等。与 DPDK/VPP 对照：这是内核路径上的 tap，和把 RX queue 交给 PMD 有不同的所有权与拷贝成本。
