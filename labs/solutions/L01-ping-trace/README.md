# L01 参考推导

本篇回答：怎样解释 ping 路径的观测缺口？前置：[完成 L01 题面](../../L01-ping-trace/)。预计阅读 8 分钟。先读题面并保存自己的记录，再读本文件，最后检查 `ping-path.bt`。本目录只有这两个文件；脚本及以下结果均【未实跑】，没有示例输出冒充实测。

GRO（通用接收聚合）入口并不只接收能合并的 TCP。`GRO_NORMAL` 会进入普通批量提交路径，见 `/home/chen/code/linux-lab/src/linux-6.18/net/core/gro.c:598` 和 `/home/chen/code/linux-lab/src/linux-6.18/include/net/gro.h:520`。因此 ICMP 也可能经 list 分发。`napi_gro_receive` 在 `/home/chen/code/linux-lab/src/linux-6.18/include/linux/netdevice.h:4190` 是 inline，不能承诺独立 kprobe 符号存在；脚本使用 `gro_receive_skb`。

可用下图作为**源码关系图**，不能作为本次执行日志。省略了路由、netfilter、邻居及 qdisc 分支：

```mermaid
flowchart LR
    N[virtio RX / NAPI] --> G[gro_receive_skb]
    G --> L[IPv4 list 或单包分发]
    L --> I[ip_local_deliver / icmp_rcv]
    I --> E[Echo 处理与回复构造]
    E --> O[IPv4 输出]
    O --> Q[设备发送队列]
    Q --> V[virtio TX]
```

`icmp_echo` 把入站头部复制到回复参数后调用 `icmp_reply`，见 `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/icmp.c:1019`；`icmp_push_reply` 用 `ip_append_data` 构建输出，见 `/home/chen/code/linux-lab/src/linux-6.18/net/ipv4/icmp.c:369`。收包 skb 与回复 skb 不能预设为同一个对象。脚本只有函数、CPU 和时间，没有包标识，所以正确结论是“受控窗口出现了这些路径阶段”，不是“所有这些行都属于 ICMP seq=1”。

<details><summary>四道思考题答案</summary>

1. 查看 `ip_list_rcv` 以及该次 pcap、ICMP 函数事件；还要区分探针不存在、没有触发和记录丢失。list 入口正常工作时不需要每次调用 `ip_rcv`。
2. VM2 PID 与 VM1 无直接关系；VM1 IRQ/softirq 的当前进程也不是远端 ping。按用户进程过滤会漏掉接收处理。
3. 不能预设。回复经过独立构造，指针还会复用；需要 ICMP id/seq、地址、方向等报文信息做关联。
4. 不能。它可能被内联、被深度限制截断、在 graph 根之外异步执行，或记录被覆盖。先查探针能力和丢记录统计。

</details>

要点回顾：双 IPv4 入口；inline 与实际符号分开；函数次数不是包数；源码关系不伪装成事件时间线。与 DPDK/VPP 对照：VPP packet trace 通常携带可关联的 buffer 信息，本脚本的函数日志没有等价的完整包身份。尚未确认项为 guest 探针可见性、实际事件与 graph 无丢失捕获。
