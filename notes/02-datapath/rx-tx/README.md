# IPv4 TCP 收发路径导读

本目录回答从 virtio-net RX buffer 到应用 `recv()`，以及应用 `send()` 到 TX 回收的端到端路径问题。面向有 DPDK/VPP 经验、首次读 Linux 内核的 C/C++ 开发者。源码基准为本地 Linux `v6.18`，所有行号相对 `/home/chen/code/linux-lab/src/linux-6.18`。

## 文件与阅读顺序

| 顺序 | 文件 | 主要内容 / 时间 |
|---|---|---|
| 1 | [01-receive-path.md](01-receive-path.md) | RX 缓冲模式、中断/NAPI、native XDP、GRO list、IPv4/early demux、TCP 接收、epoll/recv；45–60 分钟。 |
| 2 | [02-transmit-path.md](02-transmit-path.md) | send、TCP 发送约束与分段、IPv4/邻居、qdisc、virtio TX 及完成/ACK 生命周期；35–45 分钟。 |
| 3 | [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md) | 运行实验前需由环境负责人确定的地址、内核配置与设备特性；不阻塞资料阅读。 |
| 4 | [REPORT.md](REPORT.md) | 本任务交付范围、静态验证、未实跑部分和 P9 核查建议。 |

每章含 Mermaid 总览、逐阶段源码锚点、相关结构字段、设计解释、QEMU 中的 ftrace/perf 实验及示意输出、要点回顾、自测折叠答案和 DPDK/VPP 对照。章节相互链接；其他任务的基础章和全景章不是本目录完成的前置依赖。

## 使用边界与未完成项

- 主线限定 x86_64、IPv4、本机普通 TCP socket、virtio-net PCI；不覆盖 IPv6/MPTCP、bridge/OVS、无线和用户态 TCP 实现。
- 每次回到源码时先重新执行 `git describe --always --dirty --tags`；非 v6.18 或脏代码需要重新核对行号与行为。
- **实验尚未在 QEMU 实跑**；shell 代码块仅做语法检查，trace 输出均标为示意。没有给出性能实测或确定的 IRQ/接口/MSS 数值。
- native XDP/AF_XDP、RPS/RFS、threaded NAPI、busy polling、硬件卸载只说明入口/边界，未逐模式运行。软件后端写 guest 内存与最终分段位置不由 guest 源码独自证明。
- libc 的 send/recv 封装未核查，正文以源码确认的内核公共入口为准。文章的“为什么这样设计”是结合代码行为的解释，不冒充作者历史动机。

优先用外部对端的短 TCP 流量验证主线，再看 GSO metadata 与 drop reason。不要先同时更改 offload、队列分发和调度参数，否则很难将 trace 与某一条源码路径对应。
