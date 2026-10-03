# 实验参考答案与原创示例索引

本篇回答：参考答案在哪里？怎样使用代码而不跳过实验推导？前置：[实验题面总索引](../README.md)。预计阅读 5 分钟。

先完成题面记录，再看对应 README 的折叠答案，最后检查参考实现。完整实现只用于 AF_PACKET、TUN ICMP、netfilter、XDP 和非 TCP 的发流；L04 不提供 TCP 状态机。所有 VM 实验未实跑，具体静态/离线检查见 [交付报告](../REPORT.md)。

| 目录 | 文件与用途 |
|---|---|
| [L01-ping-trace](L01-ping-trace/README.md) | `README.md`、`ping-path.bt`；ICMP 阶段观察与 GRO/list 解释 |
| [L02-napi](L02-napi/README.md) | `README.md`、`napi.bt`、`budget-round.sh`；计数/直方图与预算恢复 |
| [L03-af-packet](L03-af-packet/README.md) | `README.md`、`capture.c`；绑定接口的普通 packet socket |
| [L04-raw-tcp](L04-raw-tcp/README.md) | `README.md`；手工字段、序号和关闭推导 |
| [L05-tun](L05-tun/README.md) | `README.md`、`tun_echo.c`；IPv4 ICMP 回复和 sink 模式 |
| [L06-netfilter](L06-netfilter/README.md) | `README.md`、`lab_hook.c`、`Makefile`；安全取头、匹配和五 hook 矩阵 |
| [L07-xdp](L07-xdp/README.md) | `README.md`、`drop_udp.bpf.c`；同源 count/drop 编译变体 |
| [L08-af-xdp](L08-af-xdp/README.md) | `README.md`、`icmp-load.py`；同帧输入、反射/回复辨识与 RTT |
| [L09-tcp-behavior](L09-tcp-behavior/README.md) | `README.md`、`run-round.sh`；算法/网络条件轮次与恢复 |
| [L10-tcp-trace](L10-tcp-trace/README.md) | `README.md`、`tcp-events.bt`、`one-connection.py`；事件关联与普通内核 socket 应用 |

建议顺序同题面总索引；不要在尚未确认匹配内核的 VM 上直接加载模块。C 编译产物与 Python cache 留树外；第三方 xdp-tools 不复制到本目录。

## 要点回顾

- 代码是参考，不替代自己的抓包与参数恢复记录。
- 静态编译、verifier 接受和功能实测分别报告。
- 例题数字与源码关系图不能标为实验观测。

## 总索引自测答案

<details><summary>三道答案</summary>

1. 不能。配置、符号优化、tracepoint 字段、用户态工具与驱动协商都需分别检查；还有运行流量能否触发。
2. AF_PACKET 可以看见本机发送副本，后续发送、虚拟链路或对端处理仍可能失败；需要对端或应用的独立证据。
3. L02/L07/L08/L09 都含比较环节。至少记录版本、实际负载、包长、队列/vCPU、offload、模式、采样窗口、重复轮次和恢复状态；L08 两种出口工作不同，RTT 差不能全归因于复制。

</details>

与 DPDK/VPP 对照：参考程序只覆盖特定入口或观察器；类似最小 PMD/graph 学习样例，不能把它当成已验收的生产数据面。未完成项为报告中明确列出的 VM 实跑、驱动能力与性能数据。
