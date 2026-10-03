# P6 完成报告

状态：**本次源码导读与横向比较完成；运行和完整协议/并发审计未执行，边界已显式记录。**

负责目录仅 `notes/04-userspace-stacks/`；分支 `p6-userspace`；worktree `/home/chen/code/linux-lab/ll-p6`。没有修改旧目录、根 README、AGENTS 或其他任务文件。

## 产出

共 8 个 Markdown 文件：更新目录 README，新增 `lwip.md`、`vpp.md`、`seastar.md`、`f-stack.md`、`comparison.md`、`OPEN-QUESTIONS.md`、本报告。

四个单篇覆盖架构/接收路径、缓冲区与复制、连接查找、timer、线程与 RSS、TCP 完整度、应用 API、简化取舍、项目测试。都有开头问题/前置/时间、Mermaid、自测折叠答案、DPDK/VPP 对照和只读源码练习。comparison 包含九维度表、Linux 缓冲区/并发/timer/批处理/API 对照、设计哲学、共性分歧与 10 小时阅读安排。

分阶段提交：

| 提交 | 完成模块 |
|---|---|
| `4958f3c` | lwIP |
| `c8669ee` | VPP |
| `cb0deaf` | Seastar |
| `88d09a4` | F-Stack |
| `5b5b599` | 横向比较 |
| 本报告所在提交 | README、问题清单、最终引用及能力边界修正 |

## 源码获取与验证

四个项目已全部克隆成功，固定版本与完整 hash 在 README。源码置于仓库外 `/tmp/p6-sources/`，均为浅克隆；未提交第三方源码或生成任何自制协议栈实现。初次 sandbox 网络访问失败后按已授权范围获取成功。F-Stack 试探的 `v1.24` tag 不存在，随后按任务允许的方式固定完整 commit，不假定该 tag 的存在。

Linux 在使用前经 `git describe --always --dirty --tags` 确认为 `v6.18`，本次 HEAD 为 `7d0a66e4bb9081d75c82ec4957c50034cb0ea449`。四个第三方 checkout 保持干净。

静态验收：

- 五篇正文中解析到 **303 处完整源码路径/行号引用**，逐项检查文件存在、行号不越界；此检查不等于 303 项语义已经独立复核。
- 人工复读代表性实现：lwIP active PCB 链表及 socket RX 复制、VPP ACK event 与 TIME_WAIT 设置、Seastar TIME_WAIT FIXME 与 DPDK RX 复制、F-Stack mbuf 外挂与 per-worker VNET 初始化。修正了 VPP TIME_WAIT 原先误指 CLOSE_WAIT 附近的锚点；将缩略行号展开为完整路径。
- 核对五篇各有一幅 Mermaid 和自测 `<details>`，Markdown fence 配对及本目录链接；未运行 Mermaid 渲染器。
- 全分支 `git diff --check c51a94c..HEAD`，并检查 `git diff --name-only c51a94c..HEAD` 仅包含负责目录；最终 worktree 干净。

没有编译或运行项目测试，没有启动 NIC/DPDK/EAL，没有 root 网络修改、互通抓包或性能测量。正文对项目测试的描述来自测试源码及构建入口，不冒充本次测试结果。

## 每个栈的核心洞见与局限

| 栈 | 核心洞见 | 最大局限或本次证据边界 |
|---|---|---|
| lwIP | 链表、周期扫描、raw callback 组合成容易读的小核心；少复制的代价是应用生命周期约束 | 连接规模与核心串行化约束；SACK 只确认接收端发送能力；未固定 port/offload |
| VPP | graph 批处理必须和 session FIFO、worker 所有权、event 一起理解 | packet → FIFO 有复制；错误 worker 在本版 tcp-input drop；硬件 LRO/TSO 未实测 |
| Seastar native | 连接归属、RSS 源端口选择、future 与释放动作一起减少共享状态 | native TIME_WAIT timer 未完成，keepalive 与 options 有边界；不能借 POSIX backend 的能力为其背书 |
| F-Stack | 不重写 TCP，也能通过替换设备、时间和 OS 服务改变成本结构 | 适配层不变量与线程模式审计很重；此 commit 的 thread_mode/新 ZC API 不可套旧文档 |

共同揭示的“内核瓶颈”是待测的执行/数据/摊销边界：迁核与同步、等待唤醒、每字节复制、每包重复调度。Linux 已经有批处理、非线性缓冲区和 timer wheel；用户态栈也会复制或跨核通信。源码无法得出统一性能名次，协议等待与背压也不会因 kernel bypass 消失。

## 未完成、未确认及需要关注的问题

1. **运行验证整体未执行**：四个栈均未构建/测试，所有吞吐、尾延迟、实际 zero-copy/offload 结论留待实验。
2. **lwIP**：未固定 NIC port，TSO/LRO【未确认】；timestamps 只确认选项路径，未做 PAWS/互通完整验证。
3. **VPP**：未验证任意前置 steering / 插件组合能保证 owner；本篇只确认 tcp-input WRONG_THREAD drop；LRO【未确认】，TSO 只确认 metadata 路径。
4. **Seastar**：未确认完整 native TCP 协议测试覆盖；TIME_WAIT timer、keepalive 和 SACK/TS 的实现限制本身已确认，不能写成“待看是否支持”。内存后端、LRO 构建条件和设备能力必须记录。
5. **F-Stack**：已确认 worker VNET/callwheel 初始化；全部 PCB/VNET 共享状态与锁/FD 归属审计未完成。README 中不同 FreeBSD 历史版本表述不足以确定当前移植基线，本文固定 commit 避开这一歧义。
6. **跨目录版本**：其他任务可能使用不同 lwIP/VPP tag；P9 必须先对版本，再判定差异是否错误。
7. **持久性**：源码在 `/tmp`，可能被清理；正文可由完整 hash 重建。本任务不擅自移动其他项目或提交源码副本。

需要用户后续选择的环境与实验路线已写入 `OPEN-QUESTIONS.md`；没有待批准的本次必要操作。

## 建议验收抽查

以下三处足以覆盖三种不同架构结论，均可在本地直接读取：

1. **lwIP 2.2.1**，commit `77dcd25a72509eb83f72b033d219b1d40cd8eb95`，根 `/tmp/p6-sources/lwip`：`src/core/tcp_in.c:250`，active PCB 链表循环，随后完整四元组匹配与移到表头。
2. **VPP v25.06**，commit `1573e751c5478d3914d26cdde153390967932d6b`，根 `/tmp/p6-sources/vpp`：`src/vnet/tcp/tcp_output.c:1019`，ACK 通过 session custom TX event 安排，不是独立 DELACK timer。
3. **Seastar**，commit `e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b`，根 `/tmp/p6-sources/seastar`：`include/seastar/net/tcp.hh:618`，TIME_WAIT timer FIXME 与 cleanup。

可追加 **F-Stack**，commit `eb6b32c825543a29dafcc92288e20bfd7db6362b`，根 `/tmp/p6-sources/f-stack`：`lib/ff_veth.c:475`，BSD mbuf 外挂 DPDK payload；`lib/ff_freebsd_init.c:213`，新线程模式分配 VNET。

P9 建议按四个栈各一会话，再以第五会话核对 comparison 的 Linux 对照。优先 F-Stack 新线程模式与移植边界、Seastar native 的协议缺口和测试覆盖；其次 VPP ACK/worker/FIFO，最后 lwIP SACK 方向性与 port 能力。P9 本身未在本任务执行。
