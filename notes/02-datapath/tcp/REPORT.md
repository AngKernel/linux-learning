# P4b 完成报告

任务：TCP 连接生命周期与可靠性/性能机制。工作分支 `p4b-tcp`，工作目录 `/home/chen/code/linux-lab/ll-p4b`。只修改 `notes/02-datapath/tcp/`。

## 已完成

| 文件 | 内容 |
|---|---|
| `03-connection-lifecycle.md` | 普通 IPv4 的主动/被动握手 TCP 层调用链、listen/accept、request/child/accept FIFO、syncookies、接收状态处理入口、正常关闭与 TIME_WAIT |
| `04-reliability-and-performance.md` | ACK 回收/反馈、乱序红黑树、SACK 与 RACK、各类 timer、CUBIC ops、接收窗口/内存调优、Nagle/delayed ACK、TSO/GSO 的可靠性边界 |
| `README.md` | 文件索引、阅读顺序、范围和限制 |
| `OPEN-QUESTIONS.md` | 客体探针条件与后续实验选择 |
| `REPORT.md` | 本验收报告 |

两章各有一张 Mermaid 总览图，调用链、相关字段、至少三条设计取舍、bpftrace 客体实验及示意输出、五道自测题与折叠答案、用户态协议栈启示及 DPDK/VPP 对照。未包含用户态 TCP 实现，未提交第三方源码。

## 源码与验证

- 使用前读取本 worktree 的 AGENTS.md，并两次核验内核源码的 `git describe --always --dirty --tags`，结果均为 `v6.18`。
- 按函数定义、调用点、结构字段、sysctl 注册和 tracepoint 定义进行本地源码核对。没有将旧版文章或旧笔记视为源码证据；没有引用未访问的外部资料。
- 对两章中全部显式 `文件路径:行号` 运行存在性/行号范围检查，并打印引用行人工核对。对函数起始行的偏差已修正。
- 对全部 Bash 示例执行 `bash -n`；对第 3 章嵌入的 Python 示例执行 `ast.parse`。这些是语法检查，不是实际网络实验。
- 提交前执行 `git diff --check`。所有阶段提交以 `P4b: ` 开头。

阶段提交：

1. `5fd0a64`：第 3 章。
2. `0e2774f`：第 4 章，并统一第 3 章引用格式。
3. 后续索引/报告提交：本报告与 README、OPEN-QUESTIONS；以分支 `git log` 为准。

## 未完成或未确认

1. **QEMU 客体实验未实跑。** 全部运行输出是预期形状；没有吞吐、时延、重传次数等测量值。宿主内核不能代替 v6.18 运行证据。
2. bpftrace 版本、所需客体配置、静态函数是否存在于可探针集合未确认；命令要求先列出探针。缺少探针不能推断协议未执行。
3. 尚未做 Nagle/delayed ACK 小请求时延的控制变量实验，也未测真实 NIC 或 virtio-net 的 TSO 性能。第 4 章给出 veth 可控链路与明确限制。
4. 未展开 Fast Open、DEFER_ACCEPT、ECN、全部关闭错误分支、全部 DSACK 恢复撤销条件。它们不在本次普通路径主线中，不能将文中主路径当作所有配置的唯一行为。

## 需要关注的判断

- 半连接对象在 v6.18 的普通路径进入 ehash；accept 队列由 request 节点引用 child。避免套用旧版“监听 socket 私有 SYN 链表”的图。
- 普通握手的 child 加入 accept FIFO 与处理最终 ACK 的状态转换有先后和锁边界，不是一个无锁原子搬运步骤。
- syncookies 仍有临时 request；它不解决 accept 队列满的问题。
- RACK 基于本地发送时间，不是固定三个重复 ACK，也不是必须等待 REO_TIMEOUT；`tcp_is_reno()` 指未协商 SACK，不代表拥塞算法名。
- REO_TIMEOUT、LOSS_PROBE、RETRANS、PROBE0 复用 write timer；函数调用次数不能直接等同成功发包次数。
- 第 4 章接收调优按 v6.18 的 `tcp_rcvbuf_grow()` 编写，包含用户锁、上限和乱序跨度的影响。

## 建议调度者抽查的三处引用

1. `net/ipv4/inet_connection_sock.c:1400`：`inet_csk_reqsk_queue_add()` 设置 `req->sk = child` 并链接 accept FIFO，对应第 3 章。
2. `net/ipv4/tcp_timer.c:691`：`tcp_write_timer_handler()` 按 `icsk_pending` 分发四类事件，对应第 4 章。
3. `net/ipv4/tcp_input.c:894`：`tcp_rcvbuf_grow()` 的条件、预算增长、乱序跨度与上限，对应第 4 章。

建议 P9 将连接/队列/关闭与 ACK/RACK/缓冲调优拆成两个独立复核会话；优先核对以上三处，并在 v6.18 客体完成实验后再补运行记录。
