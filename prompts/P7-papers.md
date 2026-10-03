（本提示词交给 ChatGPT Work 或深度研究执行，不由 Codex 执行。产出手动保存到 linux-learning 的 notes/05-papers/。）

背景：我是网络数据面开发（VPP/DPDK），正在系统学习 TCP 协议栈的设计：一边读 Linux 内核 TCP 源码，一边读开源用户态协议栈源码。目标是理解"内核协议栈 vs 用户态/旁路协议栈"这条路线上的设计原则和取舍。请帮我研读这一领域的关键论文。

请先核实每篇论文的作者、会议和年份；找不到原文的明确说明，不要凭印象写。候选清单（可以增删，但要说明理由）：
- 内核开销分析：Understanding Host Network Stack Overheads（SIGCOMM 2021）
- 用户态协议栈：mTCP（NSDI 2014）、Sandstorm（SIGCOMM 2014）、StackMap（ATC 2016）、TAS（EuroSys 2019）
- 数据面操作系统：IX（OSDI 2014）、Arrakis（OSDI 2014）、ZygOS（SOSP 2017）、Shenango（NSDI 2019）、Caladan（OSDI 2020）
- 工业界：Google Snap（SOSP 2019）
- 统一抽象：Demikernel（SOSP 2021）
- 拥塞控制与 pacing：BBR（ACM Queue 2016）

每篇论文输出：
1. 它针对内核协议栈的哪个具体问题（引用论文给出的测量数据）
2. 核心设计（不超过 5 条），每条说明是为了消除哪项开销
3. 它放弃了什么：兼容性、隔离、通用性、CPU 效率等
4. 评测结论，以及评测场景是否有利于它（例如只测短连接或小消息）
5. 后来的影响：哪些思想被 Linux 内核吸收了（例如 busy polling、AF_XDP、io_uring 等方向），哪些没有，为什么

最后的综合：
- 一条时间线：这十多年里大家对"网络栈瓶颈在哪里"的认识是怎么变化的
- 一张设计空间表：横轴为关键设计维度（内核/用户态、轮询/中断、run-to-completion/流水线、按核分片/共享、零拷贝程度、API 形态），纵轴为各个系统
- 内核社区对这些工作的回应：哪些问题内核已经解决或部分解决了，现在内核和用户态栈的差距主要还剩在哪里
- 给我的一份精读清单：只读 3 篇的话读哪 3 篇，理由是什么
