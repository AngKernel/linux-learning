# 动手实验：从一次 ping 到 AF_XDP 与 TCP 观测

本篇回答：先做哪些实验？每个实验怎样与笔记对应？哪些代码和结果已验证？前置阅读：[内核基础](../notes/00-kernel-basics/README.md)、[网络全景](../notes/01-overview/README.md)、[环境搭建](../env/README.md)。预计阅读 10 分钟，完成全部实验约 15–22 小时，首次环境构建另计。

本目录提供 L01–L10 题面、分层提示及 `solutions/` 参考答案。**十个 VM 实验均未实际运行成功验收**；C/BPF 编译和离线逻辑验证的具体范围见 [REPORT.md](REPORT.md)。文中的预期现象、例题序号和空白表都不是实测数据。不提交 pcap、第三方源码、二进制或用户态 TCP 栈实现。

## 文件、阅读顺序与耗时

先看对应笔记，写下自己的预测，再按题面操作，最后看 [solutions 索引](solutions/README.md)。顺序建议为 `L01 → L02 → L03 → L05 → L06 → L07 → L08 → L04 → L09 → L10`；L04 需要更多手工推导，可在 L03 后先试一轮。表中的时间是操作估计，不是性能数据。

| 实验 | 内容/目标 | 对应笔记章节 | 操作耗时 |
|---|---|---|---|
| [L01](L01-ping-trace/README.md) | ftrace/bpftrace 跟踪 ICMP 接收与回复 | [执行上下文](../notes/00-kernel-basics/)、[RX/TX](../notes/02-datapath/rx-tx/) | 45–60 分钟 |
| [L02](L02-napi/README.md) | NAPI、软中断 CPU 分布、两层预算和 coalescing | [内核基础](../notes/00-kernel-basics/)、[RX/NAPI](../notes/02-datapath/rx-tx/) | 60–90 分钟 |
| [L03](L03-af-packet/README.md) | 自写 AF_PACKET C 程序，与 tcpdump 对照 | [全景](../notes/01-overview/)、[RX/TX](../notes/02-datapath/rx-tx/) | 60–90 分钟 |
| [L04](L04-raw-tcp/README.md) | raw socket 人工握手/GET/关闭、RST 对照 | [TCP 连接与可靠性](../notes/02-datapath/tcp/) | 2–3 小时 |
| [L05](L05-tun/README.md) | TUN 读写、手工 IPv4 ICMP Echo | [RX/TX](../notes/02-datapath/rx-tx/)、[用户态栈入口](../notes/04-userspace-stacks/) | 90–120 分钟 |
| [L06](L06-netfilter/README.md) | netfilter 模块、五 hook 与三种路由路径 | [RX/TX](../notes/02-datapath/rx-tx/)、[内核基础](../notes/00-kernel-basics/) | 2–3 小时 |
| [L07](L07-xdp/README.md) | XDP 计数/丢弃，受控窗口对比 INPUT 丢弃 | [RX/TX 与 XDP](../notes/02-datapath/rx-tx/) | 2–3 小时 |
| [L08](L08-af-xdp/README.md) | AF_XDP copy/zero-copy 协商，对比 TUN | [用户态栈](../notes/04-userspace-stacks/)、[RX/TX](../notes/02-datapath/rx-tx/) | 2–3 小时 |
| [L09](L09-tcp-behavior/README.md) | CUBIC/BBR、netem、ss 指标 | [TCP 性能机制](../notes/02-datapath/tcp/)、[TCP 设计](../notes/03-tcp-design/) | 60–90 分钟 |
| [L10](L10-tcp-trace/README.md) | 状态迁移/重传事件、socket 生命周期时间线 | [TCP 连接](../notes/02-datapath/tcp/)、[TCP 设计](../notes/03-tcp-design/) | 60–90 分钟 |

每个 `Lxx-*/README.md` 是题面；对应 `solutions/Lxx-*/README.md` 是解释与折叠答案。参考实现/脚本只在 solutions 下：AF_PACKET、TUN ICMP、netfilter 模块、XDP 计数/丢弃、非 TCP 的 ICMP 发流工具以及观测/恢复 helper。`REPORT.md` 记录交付与检查；`OPEN-QUESTIONS.md` 记录运行前仍需用户决定的版本、设备能力与后续实测安排。

## 统一执行约定

- 内核源码只读：`/home/chen/code/linux-lab/src/linux-6.18`；使用前 `git describe --always --dirty --tags` 必须得到 `v6.18`。运行 guest 还需 `uname -r` 为对应构建的 6.18，源码标签与运行版本各自检查。
- 按 [env](../env/README.md) 使用 quick 或 cloud。guest 中仓库为 `/work`，VM1/VM2 实验地址为 `192.0.2.11/.12`，cloud 数据 NIC 为 `lab0`；quick 按实验地址/MAC 确认 `LAB_IF`，不要误用下载/管理 NIC。
- 示例命令除明确标注“宿主”外均在 guest。日志、pcap、自己的草稿、编译产物放 `/tmp/lXX` 等树外目录；guest 重启可能清掉 `/tmp`，需要保留的证据在实验后复制到树外持久目录。
- 追踪工具先做 discover/list，再挂载，再用流量证明触发。源码中存在探针不等于目标机一定可用。函数 tracing 不能按本机用户 PID 覆盖整个异步网络接收。
- 修改 sysctl、coalescing、队列、qdisc、XDP、iptables 前保存原值/状态；题面写明恢复方法。只在专用 VM 做实验，不在宿主管理网络执行清理。L09 的 helper 只接受自己建立的 fq 基线；L08 接管整队列可能短暂中断数据 SSH，使用独立管理通道或题面的有界后台轮次。
- L06 必须使用宿主外置的目标 6.18 `BUILD_DIR` 和匹配 `Module.symvers`，不能使用宿主 `/lib/modules/$(uname -r)/build`。模块源码是原创练习，目标编译/加载仍待实测。

额外工具按各题面核对：bpftrace ≥ 0.21、socat/xxd、支持 BPF target 的 clang、bpftool、带 `xsk-drop`/`xsk-tx` 的 xdp-tools；sysstat 的 mpstat 可用于 CPU 采样。P3 的环境脚本不是这些依赖均已安装的证明。P2 示例以 bpftrace 0.24 为基准，而 P3/本题面给出 ≥0.21 门槛；应统一实际版本后再做脚本编译/挂载验收，目前没有验证跨版本兼容。当前 P3 构建还受 pahole 等依赖缺失限制，本任务没有自动安装工具、启动 guest 或加载模块/BPF。

## 范围与尚未完成项

L04 使用现成 socat raw socket 逐包注入，报文由读者手工填写，答案只推导字段/序号；遵守根 `AGENTS.md` 不提供 TCP 客户端或协议栈状态机。L05 只支持未分片、无 options 的 IPv4 ICMP；L07 只匹配无 VLAN 的未分片 IPv4 UDP/9000；L08 使用相同 ICMP 输入比较两种整体路径，不隔离 API 单项开销。

未完成的**运行验收**包括：所有 VM 端到端步骤、bpftrace 编译/挂载、netfilter 目标编译和加载、XDP verifier 与 native/generic、AF_XDP copy/zero-copy、设备 coalescing，以及全部性能数值。文档/参考材料已交付；能力不支持的分支应记录真实错误并完成题面的替代路径，不虚构数值。

## 要点回顾

- 先预测与记录，再看 solutions。
- 版本、可挂载、确实触发是三层检查。
- 参数恢复与证据保存都属于实验完成条件。
- 一次函数调用、一个 skb、一个线上包可能不是同一口径。
- 用户态入口练习不等于实现了 TCP 可靠协议。

## 自测题

1. guest 能启动，是否意味着所有 bpftrace 探针和 XDP 模式均可用？
2. 为什么不能把本机 AF_PACKET 抓到的发送帧当成对端已接收？
3. 哪些实验可以做性能比较，报告至少要保存哪些控制条件？

答案见 [solutions 索引末尾](solutions/README.md)。

## 与 DPDK/VPP 的对照

沿用你熟悉的“拓扑→入口→buffer 所有权→节点处理→出口→端点协议”顺序，但多加内核执行上下文、skb 非线性、socket 状态与 tracing 能力这些维度。RSS、burst、mempool 的经验有助于设计控制变量；不能把内核软中断调度、TUN 和 AF_XDP 直接当成同一个 PMD 模型。
