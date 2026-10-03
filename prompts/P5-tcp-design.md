背景：我是 C/C++ 开发，做过 VPP/DPDK 用户态数据面，正在读 Linux 6.18 网络子系统（之前从没读过内核）。另有笔记按"数据包路径"讲调用链。本任务换一个角度：按设计问题横向切入，帮我理解内核 TCP 栈为什么这样设计、做了哪些取舍、付出了什么代价。这是纯理解型任务，不写任何协议栈代码。

源码：/home/chen/code/linux-lab/src/linux-6.18。
- 函数名、结构体、调用关系都必须先在源码里 grep 确认，不能凭记忆；确认不了的标"未确认"
- 回答"为什么"时，优先引用一手证据：相关代码的 git 历史（用 git log -S、git log -L、git blame 找到引入该设计的 commit，摘要其 commit message 里的动机和测试数据）、代码注释、Documentation/networking/ 下的文档。如果仓库是浅克隆，先补全历史（git fetch --unshallow），做不到就说明
- 引用外部资料（LWN 文章、netdev 大会论文等）时，只引用你能实际访问到的，并给出链接；访问不到的不要编造

输出到 notes/03-tcp-design/，每个主题一个文件。

每个主题统一格式：
1. 问题：要解决什么问题，不解决会怎样
2. 约束：内核作为通用协议栈面临的约束（要服务成千上万种应用、多租户隔离、公平性、安全性、要兼容几十年来的各种行为）
3. 方案：内核怎么做的，关键代码位置（文件路径:行号）和关键数据结构字段
4. 演进：这个设计是哪几个关键 commit 引入或改变的（hash + 作者 + 一句话动机 + commit message 里给出的性能数据）
5. 取舍：得到了什么，付出了什么代价；在哪些场景下这个设计反而成为负担
6. 对照：典型用户态协议栈（lwIP、VPP host stack、Seastar、mTCP 等）怎么处理同一个问题，为什么可以做不同的选择
7. 验证（可选）：用 bpftrace、perf 或 sysctl 对比实验观察这个设计的效果

主题（按顺序完成）：
A. 数据与内存
  A1 sk_buff 的设计：线性区与分片、clone 与共享、头部预留空间，为什么不用更简单的连续缓冲区
  A2 socket 内存记账与内存压力：每个 socket 的预分配额度、全局 TCP 内存限制、内存压力下的行为
  A3 拷贝的代价与零拷贝的演进：MSG_ZEROCOPY、接收侧零拷贝、devmem TCP 等，各自的适用条件和限制
B. 并发
  B1 socket 锁的双重模式：进程上下文持锁时软中断如何处理（backlog 队列），为什么这样设计
  B2 连接查找表的无锁读：RCU 和 SLAB_TYPESAFE_BY_RCU 在 socket 查找中的用法
  B3 多核扩展：RSS/RPS/RFS/XPS、SO_REUSEPORT、监听 socket 的可扩展性改造（请求 sock 的存放位置、无锁 listener）
C. 批处理与硬件卸载
  C1 NAPI 预算与中断缓解
  C2 GRO/GSO/TSO：分段工作放在哪一层做，为什么
  C3 发送侧排队控制：TSQ（TCP Small Queues）、BQL、autocorking，它们分别解决什么问题
  C4 busy polling：用 CPU 换延迟的这一侧
D. 时间
  D1 定时器：时间轮定时器与高精度定时器在 TCP 中的分工
  D2 pacing 与 EDT（Earliest Departure Time）模型：TCP 内部 pacing 和 fq qdisc 的关系
  D3 RTT 估计、RTO、delayed ACK 与 quick ACK
  D4 TIME_WAIT 与 minisock：为什么不保留完整的 sock
E. 可扩展性与可插拔
  E1 拥塞控制的 ops 框架（CUBIC、BBR）以及用 BPF struct_ops 实现拥塞控制
  E2 ULP（如 kTLS）与 sockops 等 BPF 挂载点
F. 安全与健壮性（我的工作是网络安全方向，这一块请多写一点）
  F1 SYN flood 与 syncookies
  F2 典型 TCP 漏洞如何影响了设计：challenge ACK 相关的侧信道（CVE-2016-5696）、SACK 相关的拒绝服务（CVE-2019-11477 等），修复方式分别是什么
G. 通用性的代价
  G1 一次 recv/send 的开销都花在哪里：系统调用、拷贝、上下文切换、缓存污染、锁。给出用 perf 测量这些开销的方法
  G2 这些代价正是 kernel-bypass 和用户态协议栈存在的理由。用户态栈为了省掉它们，放弃了内核的哪些保证

最后一份总结（notes/03-tcp-design/principles.md）：
- 从以上主题中提炼 10–15 条贯穿内核网络栈的设计原则（例如"快路径优先，慢路径兜底""批处理摊薄固定开销""能下沉到硬件的就下沉"），每条都要有至少两个主题作为证据
- 一张表：每条原则在用户态协议栈中是继续成立、被放大，还是不再必要

一次做完全部主题，不要中途停下等待确认。
