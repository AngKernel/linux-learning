# TCP 机制阅读入口

本目录回答普通 IPv4 TCP 连接如何建立、交付、关闭，以及可靠传输与性能控制如何相互配合。面向熟悉 DPDK/VPP、首次阅读内核网络栈的 C/C++ 开发者。

源码基准为 `/home/chen/code/linux-lab/src/linux-6.18` 的 `v6.18`；两章引用的路径均相对此源码根目录。阅读前建议再次执行 `git -C /home/chen/code/linux-lab/src/linux-6.18 describe --always --dirty --tags`，避免把行号套用到其他版本。

| 文件 | 内容 | 建议顺序与时间 |
|---|---|---|
| [03-connection-lifecycle.md](03-connection-lifecycle.md) | listen/accept、请求与 child、三次握手、syncookies、关闭与 TIME_WAIT | 先读，约 45 分钟 |
| [04-reliability-and-performance.md](04-reliability-and-performance.md) | ACK、乱序/SACK/RACK、定时器、CUBIC、接收调优、Nagle、ACK 策略与 TSO/GSO | 后读，约 60 分钟 |
| [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md) | 下一轮实验选择与待确认条件 | 准备实跑时阅读 |
| [REPORT.md](REPORT.md) | 完成范围、验证记录、局限及建议抽查引用 | 验收时阅读 |

前置知识仅要求 TCP 协议和 socket API；内核对象概念可搭配 `notes/00-kernel-basics/`。本目录不依赖同时生成的 `notes/02-datapath/rx-tx/` 内容，也不覆盖 IP、驱动和完整系统调用实现。

两章均有 Mermaid 图、带源码位置的调用链、字段表、设计取舍、QEMU 客体实验、自测题及折叠答案、DPDK/VPP 对照和用户态协议栈设计启示。实验中的 Python 只使用现成 socket API 产生流量，没有实现用户态 TCP。

尚未完成或未确认：

- **全部 QEMU 实验未实跑。** 已完成 shell 语法与嵌入 Python 语法检查，预期输出明确写为示意。宿主内核不作为 v6.18 实验证据。
- 客体的 bpftrace 版本、配置、静态函数是否可探测以及 ethtool offload 能力，需要在启动 v6.18 客体后确认。
- 小请求 Nagle/delayed ACK 的定量对照和真实/虚拟网卡 TSO 性能没有测量。veth 流量不能证明物理设备收益。
- 主线未展开 Fast Open、DEFER_ACCEPT、ECN、所有错误恢复、IPv6 或 MPTCP；涉及例外的位置已说明。
- 源码依据已核对，但仍建议 P9 独立复核握手并发、RACK 定时器与接收内存调优三处。
