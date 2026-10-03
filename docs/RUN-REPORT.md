# 学习资料生成任务交付报告

日期：2026-10-03，时区 Asia/Shanghai。本文说明八个任务的交付、验收边界、未完成验证和后续核查安排。前置阅读：[仓库约定](../AGENTS.md)。预计阅读时间：10 分钟。

## 执行结果与统计口径

八个任务均已完成资料交付、通过本次验收并普通合并到 main；合并结果 `61a049d` 已推送到 origin。本报告作为后续独立提交保存。P7、P9、P10 未执行；八个任务分支和 worktree 全部保留。

开工检查通过：当前分支为 main、工作区干净、AGENTS.md 已提交。内核目录 `/home/chen/code/linux-lab/src/linux-6.18` 存在，`git describe --always --dirty --tags` 为 `v6.18`，不是浅克隆，因此无需 unshallow。内核树原有未跟踪的 `notes/` 被保留，未用作源码依据。

所有提示词的内核路径占位符已在独立提交 `c51a94c` 中替换。之后创建八个独立分支和 worktree，按 P1、P2、P4a、P4b、P3、P5、P6、P8 的顺序启动。原生代理容量包含调度器，故最多同时运行三个子代理；后期 P8 的四组观测文档由助手在互不重叠目录协作，仍由 P8 主代理统一提交。调度器未编写学习笔记。

下表的“提交数”统计 `c51a94c..任务分支`，不计 main 上的准备、合并和本报告提交；“产出文件数”统计同一区间新增或修改的文件，包含 README、REPORT 和 OPEN-QUESTIONS，不等同于正文篇数。

| 任务 | 状态 | 分支 / 验收末提交 | 提交数 | 产出文件数 | 主要内容 |
|---|---|---|---:|---:|---|
| P1 | 已合并 | p1-overview / 0b8916c | 5 | 13 | 八篇全景地图、110 条术语、源码行数脚本与 TSV |
| P2 | 已合并 | p2-basics / 3586f16 | 9 | 11 | 八篇内核基础、源码阅读与观测方法 |
| P3 | 已合并 | p3-env / 477d353 | 3 | 27 | Kbuild、97 项配置、两种 VM 启动方式、两机拓扑及追踪库 |
| P4a | 已合并 | p4a-rxtx / 0683819 | 4 | 5 | virtio_net 收发路径、GRO、qdisc、设备回收与 TCP ACK |
| P4b | 已合并 | p4b-tcp / 453f865 | 3 | 5 | 连接建立/关闭、可靠性、timer、接收调优与拥塞控制 |
| P5 | 已合并 | p5-design / 8787f54 | 7 | 24 | 20 个 TCP 设计主题、12 条原则、历史演进与安全修复 |
| P6 | 已合并 | p6-userspace / 4f52a73 | 6 | 8 | lwIP、VPP、Seastar、F-Stack 固定版本导读与比较 |
| P8 | 已合并 | p8-labs / 47a5ff1 | 11 | 36 | 十个实验、独立 solutions、观测脚本与原创非 TCP 栈示例 |

合计 **48 次任务提交、129 个产出文件**。不包括提示词准备提交和 `docs/` 本报告及目录说明。所有任务目录都有 README、REPORT 与待决事项；P3 在 env 和 traces 分别提供报告，追踪库的待决事项统一指向 env。

worktree 位于仓库父目录的 `ll-p1`、`ll-p2`、`ll-p3`、`ll-p4a`、`ll-p4b`、`ll-p5`、`ll-p6`、`ll-p8`，均可沿原分支继续工作。

## 验收记录

每个任务均检查了阶段提交、README/REPORT、`git diff --stat main...分支` 的目录范围，并抽查至少三处源码引用的实际上下文。没有合并越界修改，没有提交第三方源码或用户态 TCP 协议栈实现。普通 merge 保留了各任务提交，未 rebase、未 force；没有合并冲突。P4a 的一次尾随空格在原分支补交修复后再次合并，完整分支差异检查通过。

P8 的 raw TCP 要求与仓库“不要编写用户态 TCP 协议栈实现”约定同时适用：L04 采用人工核对序列号、逐包操作的实验说明，不交付自动 TCP 状态机或 HTTP TCP 客户端实现。AF_PACKET、TUN ICMP、netfilter 和 XDP 示例属于各自实验范围。

源码抽查记录如下；行号以 Linux v6.18 或 P6 明确固定的项目版本为准。

| 任务 | 抽查位置与结论 |
|---|---|
| P1 | `include/linux/net.h:116` 的 socket 关联；`net/core/dev.c:5930` 的 ingress 顺序；`net/ipv4/fib_frontend.c:910` 的路由配置入口 |
| P2 | `net/socket.c:2284` 的 fd 获取；`net/core/dev.c:1528` 的 RCU 发布；`drivers/net/ethernet/stmicro/stmmac/stmmac_main.c:2064` 的 page_pool 配置 |
| P3 | `include/linux/netdevice.h:4190` 的 inline 包装；`net/core/gro.c:624` 的实际接收函数；`net/ipv4/ip_input.c:648` 的 IPv4 list 路径 |
| P4a | `net/ipv4/ip_input.c:337` 的 early demux 条件；`net/ipv4/tcp_input.c:6395` 的快速入队；`drivers/net/virtio_net.c:598` 的设备完成回收 |
| P4b | `net/ipv4/inet_connection_sock.c:1400` 的 accept FIFO；`net/ipv4/tcp_timer.c:691` 的四类 write timer；`net/ipv4/tcp_input.c:894` 的 rcvbuf 增长 |
| P5 | `net/ipv4/inet_hashtables.c:549` 的持引用后身份复查；`net/ipv4/tcp_output.c:1208` 的 per-CPU BH work；`net/ipv4/tcp_input.c:1716` 的 SACK 合并边界 |
| P6 | lwIP `src/core/tcp_in.c:250` 的 PCB 链表；VPP `src/vnet/tcp/tcp_output.c:1019` 的 ACK event；Seastar `include/seastar/net/tcp.hh:618` 的 TIME_WAIT FIXME；另查 F-Stack `lib/ff_veth.c:475` 的外挂数据 |
| P8 | `include/uapi/linux/if_packet.h:14` 的 packet socket 地址；`drivers/net/virtio_net.c:1804` 的 XDP action 分发；`drivers/net/virtio_net.c:5921` 的 XSK pool 与 headroom/queue 检查 |

额外验证：P1 源码统计脚本复跑与 TSV 一致；P2/P4 的 shell/Python 示例做了语法检查；P3 的 14 个 shell 脚本及公开帮助入口通过，错误路径与 UDP 参数转发做了检查；P5 核查 49 个历史 hash 均属于 v6.18 历史；P6 核对四个 checkout 的完整 hash 和引用位置。引用存在和语法通过均不代表所有推论已完成独立事实核查。

P8 示例代码另做独立抽检：AF_PACKET、TUN、XDP count/drop 严格编译通过；TUN 的 3 个正常回复和 12 个拒绝输入案例通过 ASan/UBSan。观测模块的 shell/Python 语法及 tracepoint 字段按源码检查。L07 发现并修复“先 DROP 导致 iperf3 UDP 无法建流”的阻塞，改为先稳定发流再开启丢弃，并排除切换时段；另修正 BPF license 符号冲突和 L09 的 fq/netem 句柄冲突。这些检查没有加载模块或 BPF。

监控和逐任务验收记录位于仓库外 `../ll-logs/STATUS.md`、`STATE.json`、`P*.log`、`P*-acceptance.txt`，P6 另有 `P6-source-acceptance.txt`。原生代理日志是状态摘要与 Git 快照，不是后台 CLI 的完整 stdout。执行期间未遇用量上限或任务异常退出；格式修复和 P8 助手协作均不属于失败重启。

## 各任务未完成验证与问题汇总

**资料与脚本已交付，但完整 v6.18 运行验收尚未完成。** P3 实际调用 selftest，在编译前因缺少 pahole 返回失败，未进入 VM、发流与追踪。宿主 KVM API 12 与创建 VM 检查成功，不能把问题归因于不支持虚拟化。其余缺项包括 virtme-ng、bpftrace、cloud-localds；按任务要求未自动安装依赖。

| 来源 | 未完成、未确认与适用边界 |
|---|---|
| [P1 REPORT](../notes/01-overview/REPORT.md) | 网络观察未运行，Mermaid 未渲染；IPv4 普通路径为主，IPv6、bridge、隧道、XFRM 和硬件卸载不构成完整执行图；iproute2 映射固定 v6.18.0，非宿主版本声明。 |
| [P2 REPORT](../notes/00-kernel-basics/REPORT.md) | 未编译内核、生成索引或运行 VM/BPF/perf；NAPI 线程、RSS、探针能力依赖目标；不展开 PREEMPT_RT、其他架构 ABI 与 NMI 分配细节。 |
| [P3 环境 REPORT](../env/REPORT.md)、[追踪 REPORT](../traces/REPORT.md) | olddefconfig 依赖闭包、内核构建、两种 VM 引导、镜像分区、共享目录、SSH、流量、GDB、BPF parser/verifier/挂载与成功 selftest 均待实跑。Ubuntu 候选 bpftrace 0.14 不满足库要求 ≥0.21；perf/bpftool 与 guest 兼容性待验。 |
| [P4a REPORT](../notes/02-datapath/rx-tx/REPORT.md) | QEMU/ftrace/perf、XDP、RSS/RPS/RFS 和 offload 组合未运行；guest 配置、virtio 协商与真实分段点未验证；未核查 libc 包装。 |
| [P4b REPORT](../notes/02-datapath/tcp/REPORT.md) | 静态函数可探测性、Nagle/delayed ACK 控制变量与 TSO 性能未测；未展开 Fast Open、DEFER_ACCEPT、ECN、全部关闭错误分支与 DSACK 撤销条件。 |
| [P5 REPORT](../notes/03-tcp-design/REPORT.md) | 无性能实测；pre-Git 初次引入证据保留未确认；未穷尽 RSS 等历史、io_uring ZC Rx ABI 或 Seastar EDT 等价机制。历史性能数字保留原条件，未复测。 |
| [P6 REPORT](../notes/04-userspace-stacks/REPORT.md) | 四个栈均未构建/运行。lwIP port/offload、VPP steering/LRO、F-Stack 全部 PCB/VNET/锁/FD 归属待查；Seastar native TIME_WAIT/keepalive/选项实现限制已在源码确认，不能误写为完整支持。源码在 `/tmp`，可能被清理。 |
| [P8 REPORT](../labs/REPORT.md) | 十个 VM 实验均未完整运行。netfilter 目标编译/加载、BPF 动态编译/挂载、XDP verifier、AF_XDP 协商及性能数值待验；xdp-bench 未安装、CLI 待固定版本检查。L08 的整体 RTT 差不代表一次复制开销，Python 发流器可能先饱和。 |

各正文的预期输出和示意图不是运行记录；Mermaid 尚未统一用目标阅读器渲染。P5 前六篇部分对照版本与 P6 不同，各有出处，后续必须先对版本再比较。

## OPEN-QUESTIONS 汇总

这些事项未阻塞本次生成，也未要求用户中途批准。P3 已提供 virtio_net、两机 `192.0.2.0/24` 的候选实验基线；实际引导成功后，才能关闭其他目录中关于环境的待决项。

| 来源 | 后续需要选择或验证的事项 |
|---|---|
| [P1](../notes/01-overview/OPEN-QUESTIONS.md) | 首个设备/驱动；透明桥还是路由安全拓扑；IPv6/加密专题时机；Mermaid 阅读器。 |
| [P2](../notes/00-kernel-basics/OPEN-QUESTIONS.md) | VM 实际接口及多队列；统一 bpftrace 版本（本篇示例按 0.24）；用于逐字段比较的 DPDK/VPP 版本；是否另补 RT。 |
| [P3](../env/OPEN-QUESTIONS.md) | quick 工具来源或先用 cloud；固定 Debian 镜像及根分区；已有 Docker/libvirt 防火墙兼容性；完整 selftest；匹配模块、perf/bpftool 选择。 |
| [P4a](../notes/02-datapath/rx-tx/OPEN-QUESTIONS.md) | 确认跨 virtio 的真实对端、接口和配置；记录协商能力与可用探针；正式 trace 的运行负责人和保存位置。 |
| [P4b](../notes/02-datapath/tcp/OPEN-QUESTIONS.md) | guest 探针集合；是否增加小请求延迟实验；virtio 或真 NIC 的分段验证；普通握手/关闭之后的深入机制顺序。 |
| [P5](../notes/03-tcp-design/OPEN-QUESTIONS.md) | 小 RPC 尾延迟、吞吐或 CPS 的负载优先级；devmem 所需 NIC/dma-buf 设备；对照版本统一；是否追查 pre-Git 归档。优先核对安全、zero-copy、pacing/扩展及成本统计。 |
| [P6](../notes/04-userspace-stacks/OPEN-QUESTIONS.md) | 第三方源码长期保存；lwIP port；VPP worker/RSS；Seastar native/backend；F-Stack 模式；统一 peer 的互通与异常包测试；功能对等的性能实验；跨目录版本映射。 |
| [P8](../labs/OPEN-QUESTIONS.md) | 首次 guest 验收方式；统一 bpftrace 版本；socat/xxd 与 xdp-tools 固定版本；coalescing/native XDP/AF_XDP 协商能力；是否引入更快发包器；单向入口时延的另行实验设计；匹配模块和 trace 运行验收。 |

## P9 建议拆分与优先级

P9 本次未执行。建议按下面范围分别开会话，每次先固定版本与运行环境；源码核查与实验实跑分别记录结论。

| 优先级 | 会话范围 | 最需要先核对的内容 |
|---|---|---|
| 高 | `env/` | 配置最终生效值、legacy iptables 依赖、模块匹配、virtme 参数、cloud 分区与两种 selftest 成功路径。 |
| 高 | `traces/` + L01/L02/L10 | bpftrace 实际版本和语法、探针挂载、GRO list、NAPI 计数单位；完整 socket、request 和 TIME_WAIT 的可观测边界。 |
| 高 | `labs/` 其余实验，按设备/过滤与 TCP 行为分两组 | 编译和清理路径、namespace 隔离、L04 手工操作边界；XDP/AF_XDP copy 与 zero-copy 能力；吞吐/延迟比较的可比性。 |
| 高 | P5 F1/F2 独立会话 | cookie 适用条件、challenge ACK 默认行为、SACK 修复与后续回归；核对原始历史提交语境。 |
| 高 | P5 A1–A3；E1/E2 各一会话 | 页/数据所有权、zero-copy API 与设备限制；BPF/ULP 的执行上下文和可访问字段。 |
| 高 | P6 F-Stack、Seastar 各一会话 | 新线程模式中 VNET/PCB/锁/FD 归属；native backend 协议缺口、内存后端和测试覆盖。 |
| 中 | P4a RX、TX 各一会话 | RX 模式、XDP/GRO/list/early demux；TX 分段、TSQ/qdisc、completion 与 ACK 生命周期。 |
| 中 | P4b 两章各一会话 | request/child/accept FIFO 与关闭；ACK/RACK/timer、窗口增长和 Nagle 控制变量。 |
| 中 | P5 B；C；D；G 分四个会话 | RCU/锁与归属；两层预算/批处理；D2 EDT/fq/内部 pacing；perf 成本归因与历史数字口径。 |
| 中 | P6 VPP、lwIP、comparison 各一会话 | ACK event/错误 worker/FIFO 复制；SACK 方向与 port；先对齐固定版本再做 Linux 横向比较。 |
| 中 | P1 挂载点独立，其余合并核查 | XDP/tap/tc/netfilter 顺序与重入；socket 操作表、对象回收、控制面命令与术语一致性。 |
| 中 | P2 01/03/04、02/05/06、07/08 分三组 | 上下文/GFP/RCU；x86-64 ABI/宏/ops/清理；类比边界与运行统计口径。 |

先让环境和观测入口在 v6.18 上跑通，再逐组保存配置、命令、退出码和原始输出。正式追踪产物按仓库约定归入 `traces/`。全局学习计划、总索引整合与勘误整理不在本次 P7/P9/P10 范围内。
