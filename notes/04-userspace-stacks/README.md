# 用户态协议栈源码导读

本目录回答：成熟的用户态 TCP 路线如何组织状态、数据和时间；它们依赖哪些应用/部署假设；与 Linux 6.18 的通用接口相比换来了什么。面向熟悉 VPP/DPDK 的 C/C++ 开发者，不包含自制协议栈实现代码。

前置阅读：`../00-kernel-basics/README.md`、`../01-overview/README.md`；正文总阅读时间约 3 小时。包含源码追踪的 10 小时安排见 [comparison.md](comparison.md)。

## 文件和顺序

| 顺序 | 文件 | 内容 |
|---|---|---|
| 1 | [lwip.md](lwip.md) | 最小基准：PCB 链表、pbuf 生命周期、周期扫描和 raw / socket API |
| 2 | [vpp.md](vpp.md) | 熟悉 graph 上补齐 TCP、session FIFO、worker 归属与 ACK event |
| 3 | [seastar.md](seastar.md) | shard / future / fragment，区分 native 与 POSIX、区分两种 DPDK 内存后端 |
| 4 | [f-stack.md](f-stack.md) | BSD 栈移植边界、两个 mbuf、callout 与 DPDK 时钟、版本中的新线程模式 |
| 5 | [comparison.md](comparison.md) | 九维度表、设计假设、Linux 对照、共性分歧、瓶颈假设与 10 小时阅读 |
| 管理 | [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md) | 需要选择的后端/运行环境，后续核查和实验问题 |
| 验收 | [REPORT.md](REPORT.md) | 完成范围、未确认项、静态验证与建议抽查位置 |

四个项目各有架构 Mermaid、九维度分析、源码定位、只读练习、要点回顾、自测与 DPDK/VPP 对照。每篇支持程度都区分“存在结构/配置”“走到实现路径”“已实跑验证”。本次只完成前两类，未实跑任何网络栈。

## 固定源码与引用规则

| 引用前缀 | 版本 / 完整 commit | 本地只读 checkout | 实际访问的上游 |
|---|---|---|---|
| lwIP | `STABLE-2_2_1_RELEASE` / `77dcd25a72509eb83f72b033d219b1d40cd8eb95` | `/tmp/p6-sources/lwip` | [固定树](https://github.com/lwip-tcpip/lwip/tree/77dcd25a72509eb83f72b033d219b1d40cd8eb95) |
| VPP | `v25.06` / `1573e751c5478d3914d26cdde153390967932d6b` | `/tmp/p6-sources/vpp` | [固定树](https://github.com/FDio/vpp/tree/1573e751c5478d3914d26cdde153390967932d6b) |
| Seastar | `e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b` | `/tmp/p6-sources/seastar` | [固定树](https://github.com/scylladb/seastar/tree/e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b) |
| F-Stack | `eb6b32c825543a29dafcc92288e20bfd7db6362b` | `/tmp/p6-sources/f-stack` | [固定树](https://github.com/F-Stack/f-stack/tree/eb6b32c825543a29dafcc92288e20bfd7db6362b) |
| Linux | `v6.18`；每次使用前执行 `git describe --always --dirty --tags` | `/home/chen/code/linux-lab/src/linux-6.18` | 本任务依据本地已确认源码 |

单篇中未加项目前缀的 `文件路径:行号` 相对该篇开头所列 checkout；`Linux 文件路径:行号` 始终指 Linux v6.18。横向对比明确加项目前缀。路径是定位锚点，不意味着一个函数可仅凭那一行解释完整。

第三方项目都克隆在学习仓库之外，没有将其源码、构建产物或依赖提交入仓库。checkout 为浅克隆，足够核实此版本实现，不支持完整历史研究。`/tmp` 可能被清理；需要重取时按表中的上游与完整 commit 恢复，不能直接换成最新 main 后继续使用本文行号。

本目录不引用旧 `notes/userspace-stacks/` 中的结论。与其他目录对读时先核对版本：其他任务可能选择不同 lwIP/VPP tag，不能把函数名或功能差异直接当成勘误。

## 未完成或未确认

- 未编译/运行四个项目的测试，未抓包，未跑吞吐、延迟或硬件 offload 实验；笔记中的命令为只读源码观察。
- lwIP 未固定 port，TSO/LRO 端到端支持【未确认】；发送 SACK 与完整发送端 SACK 恢复严格区分。
- VPP 未固定 NIC / 接入插件组合，LRO 与实际 TSO【未确认】；已确认此版 ACK 走 event，以及错误 worker 输入的 drop 分支。
- Seastar native 的 TIME_WAIT timer 缺口、keepalive 不支持与 options 边界已由源码确认；完整 native TCP 协议测试覆盖【未确认】。DPDK LRO 还受构建宏、配置和 NIC 能力共同限制。
- F-Stack 固定 commit 中已有 thread_mode / per-worker VNET；其全部共享资源、锁与 PCB 并发语义审计未完成。不能按旧版本描述成仅支持多进程。
- 不给绝对性能排名；“潜在内核瓶颈”是待实验验证的解释框架。
