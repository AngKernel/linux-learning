# P4a 交付报告

日期：2026-10-03。分支：`p4a-rxtx`。工作目录：`/home/chen/code/linux-lab/ll-p4a`。负责范围仅为 `notes/02-datapath/rx-tx/`。

## 已完成

- `01-receive-path.md`：从 virtqueue 预填 buffer、硬中断、NAPI/NET_RX 到 XDP、skb、GRO、协议无关核心、IPv4/路由/early demux、TCP socket/快速路径、队列、epoll 通知与 recv 拷贝。含 RSS/RPS/RFS、丢弃入口与 drop reason 支线。
- `02-transmit-path.md`：send 接受字节、TCP 写队列与发送约束、分段/GSO/TSO/IP 分片、IPv4 hook、邻居解析、qdisc 调度/bypass、virtio 提交与 TX 回收，分离 TX completion 和 TCP ACK。
- `README.md`：文件索引、阅读顺序、范围与未实跑限制。
- `OPEN-QUESTIONS.md`：实验拓扑、可追踪内核/协商能力、正式 trace 的后续保存分工。
- 本报告；共 5 个文件。两章分别包含总览图、调用链与行号、结构字段、至少 3 条设计解释、实验、5 道自测及折叠答案、要点回顾、DPDK/VPP 对照与用户态栈启示。

阶段提交为 `0d37acc`（收包章）、`c67d284`（发包章）；后续交付提交补充索引、报告、注册链说明与静态核验修订。所有提交 message 均以 `P4a: ` 开头。

## 源码核查中需要保留的结论

1. v6.18 `virtio_net.c` 搜索 `page_pool` 无匹配；普通 RX 使用 small/mergeable 页片段或 big 页面链，AF_XDP 是另一条路径。不能将通用 page_pool 设施画为 virtio 的必经调用。
2. NAPI 的每次 weight、net_rx_action 的累计包预算/时间窗、通用软中断的执行限制是不同层级；TX 回收计数不能套 RX 包预算。
3. GRO 的正常批量上送可经 `ip_list_rcv()`，只追 `ip_rcv()` 会漏掉 list 路径；`napi_gro_receive()` 在本版是内联包装。
4. early demux 在 PRE_ROUTING 之后、必要的输入路由查询之前，有 dst/socket/fragment 等条件；route hint 可使它跳过。
5. TCP 数据快速分支直接调用 `tcp_queue_rcv()`；慢路径才调用 `tcp_data_queue()`。socket backlog、接收队列与 epoll ready list 不同。
6. virtio TX completion 回收可能来自 TX NAPI、RX 顺带或后续 start_xmit；普通 TX NAPI 返回 work 0 也可能已清理多项。
7. 设备消费发送副本、TCP ACK 释放重传数据是两个生命周期。virtio 意外提交失败也可消费 skb 并返回 NETDEV_TX_OK，因此不能按返回码断言线上成功。

## 验证与限制

已执行：

- 阅读本 worktree 的 AGENTS.md，确认工作分支与范围。
- 对本地内核重复执行 `git describe --always --dirty --tags`，结果 `v6.18`；确认非浅克隆。
- 使用 rg、带行号源码读取核对本文调用点、分支、结构字段、tracepoint 和所用配置符号。
- 对两章所有 `路径:行号` 做文件存在与行号范围静态检查；对实验的 11 个 shell 代码块执行 `bash -n`，对其中 Python 流量应用做编译语法检查。
- `git diff --check` 检查空白问题；内容仅 Markdown，未提交第三方源码、二进制、数据包或用户态 TCP 实现。

未执行/未确认：

- 未启动 QEMU，未执行 ftrace/perf、流量、XDP、RSS/RPS/RFS、offload 组合实验。所有 trace 输出明确标注为示意，不能当实测证据。
- 未确认最终 guest 的内核配置、模块参数、可挂载符号、virtio 协商能力、后端类型和真实分段位置。
- 未核查 libc send/recv 包装；以已确认的内核分发入口解释。
- Mermaid 图未用渲染器实测；无外部资料引用，不存在未访问网页的引用。
- 没有声称证明唯一历史设计动机；设计解释依据本版代码行为。本文是路径导读，不是对所有协议/驱动分支的形式证明。

## 建议调度者抽查的 3 处

| 章节结论 | 源码锚点 | 核对内容 |
|---|---|---|
| early demux 早于必要的路由查询，且有前置条件 | `net/ipv4/ip_input.c:337` | 先检查开关、dst、sk、fragment，TCP 分支调用 early demux；随后 367 行判断是否需路由。 |
| TCP 接收快速分支直接入队 | `net/ipv4/tcp_input.c:6395` | `tcp_queue_rcv()` 后继续 ACK/就绪处理；慢路径在 6448 行才调用 `tcp_data_queue()`。 |
| TX 设备完成释放的是送往下层的 buffer | `drivers/net/virtio_net.c:598` | 取 virtqueue used buffer、按类型 `napi_consume_skb()`，并报告完成统计；与 TCP ACK 清理 `net/ipv4/tcp_input.c:3382` 区分。 |

## P9 后续事实核查建议

- 分两个会话复核本目录：RX 会话重点核对 virtio 模式/XDP、GRO list、路由 hint 与 early demux；TX 会话重点核对三种分段、TSQ/qdisc、TX 回收与 ACK 生命周期。
- 实验会话单独保存配置与原始 trace，再替换“示意输出”。优先确认 ftrace 内联/静态符号可见性，避免将未挂到的函数当成未执行。
- 和基础/全景/TCP 机制目录交叉检查 page_pool、NAPI 预算、TCP 快慢路径、TSQ 与 epoll 的表述，避免同一版本不同章节互相矛盾。

合并、最终 RUN-REPORT 和推送由调度者负责，本分支不代替其修改其他目录。
