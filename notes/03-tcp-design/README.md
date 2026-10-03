# TCP 设计原理与取舍

本目录回答：Linux TCP 为什么这样组织数据、并发、时间与扩展？安全与通用性付出了什么成本？前置阅读：`notes/00-kernel-basics/`、`notes/01-overview/`；收发调用链对照 `notes/02-datapath/`。预计阅读：全套约 3–4 小时，可按模块分次阅读。

## 文件与建议顺序

| 顺序 | 文件 | 主要问题 |
|---|---|---|
| A1 | [sk_buff](A1-sk_buff.md) | 线性/非线性数据、clone、共享与头部空间 |
| A2 | [socket 内存](A2-socket-memory.md) | forward allocation、全局/memcg 压力与回收 |
| A3 | [零拷贝](A3-zero-copy.md) | 发送 ZC、接收页映射、devmem RX/TX |
| B1 | [socket 锁与 backlog](B1-socket-lock-backlog.md) | 进程和 softirq 如何移交协议处理 |
| B2 | [RCU 连接查找](B2-socket-lookup-rcu.md) | 对象复用、持引用、复查身份 |
| B3 | [多核与 listener](B3-multicore-listener.md) | RSS/RPS/RFS/XPS、reuseport、request/accept 分工 |
| C1 | [NAPI 预算](C1-napi-budget.md) | 批处理与 CPU 公平 |
| C2 | [GRO/GSO/TSO](C2-gro-gso-tso.md) | 聚合和分段的位置 |
| C3 | [TSQ/BQL/autocorking](C3-tsq-bql-autocork.md) | 三种排队/合包控制 |
| C4 | [busy polling](C4-busy-polling.md) | 用 CPU 换等待延迟 |
| D1 | [定时器](D1-timers.md) | 非级联时间轮与 hrtimer |
| D2 | [pacing 与 EDT](D2-pacing-edt.md) | TCP 计算时间，fq/内部 timer 分工 |
| D3 | [RTT/RTO/ACK](D3-rtt-rto-ack.md) | 估计、反馈与延迟折中 |
| D4 | [TIME_WAIT/minisock](D4-timewait-minisock.md) | 关闭后紧凑协议状态 |
| E1 | [拥塞控制 ops](E1-congestion-control.md) | CUBIC、BBR、BPF struct_ops |
| E2 | [ULP 与 BPF](E2-ulp-bpf-hooks.md) | kTLS、sockops 的边界 |
| F1 | [SYN flood/syncookies](F1-syn-flood-syncookies.md) | 推迟保留状态、协商与容量边界 |
| F2 | [安全演进](F2-security-evolution.md) | challenge ACK 侧信道与 SACK/低 MSS 修复 |
| G1 | [send/recv 成本](G1-send-recv-cost.md) | 能复查的 perf 测量方法 |
| G2 | [kernel-bypass 取舍](G2-kernel-bypass-tradeoffs.md) | 成本与系统保证由谁承担 |
| 总结 | [12 条原则](principles.md) | 每条至少两个主题证据及用户态适用性 |
| 交付记录 | [REPORT.md](REPORT.md) | 完成范围、证据检查、运行限制 |
| 待决事项 | [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md) | 后续实验环境与深入方向 |

推荐按 A→B→C→D→E→F→G 阅读，最后读原则；网络安全方向可在 A/B/C2 后先读 F。各主题统一包含问题、约束、方案、演进、取舍、用户态对照、验证方法，以及要点/自测折叠答案/DPDK 对照。

## 证据基准与版本

- Linux 源码：`/home/chen/code/linux-lab/src/linux-6.18`，已反复 `git describe --always --dirty --tags` 确认为 `v6.18`，HEAD 为 `7d0a66e4bb9081d75c82ec4957c50034cb0ea449`。
- 历史非浅克隆；查询限制相关文件或使用已定位 commit，读取完整提交正文。2005 年初始导入前的历史不自动视为已确认。
- 内核引用 `文件路径:行号` 都相对上述源码根，基于已跟踪 v6.18 文件；内核树已有未跟踪 `notes/` 不参与证据、不由本任务处理。
- 历史性能数字是提交作者的条件化测量，没有在当前机器复测。设计尺寸/计数示例与性能结果分开；未给量化数据的明确说明。
- 外部官方资料只引用实际访问内容。前 A/B 使用 lwIP 2.2.0、VPP 25.02、DPDK 24.11 文档；后续源码对照使用 lwIP 2.2.1 `77dcd25a72509eb83f72b033d219b1d40cd8eb95`、VPP v25.06 `1573e751c5478d3914d26cdde153390967932d6b`、Seastar `e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b`。不同版本没有拼成同一实现或性能曲线。
- 外部源码由其他任务放在 `/tmp/p6-sources/` 后只读核查，文中使用固定 commit 链接，不把临时克隆作为交付依赖。未提交任何第三方源码。

## 未完成、未确认与运行边界

20 个要求主题与原则总结均已成文。未完成的是运行期验证：宿主为 6.8，本任务没有可运行的 v6.18 VM，也未运行压测、漏洞复现、BPF 加载、devmem 或用户态栈。各篇的实验是待执行方法，不能当测试通过记录。

早于标准 Git 历史的 sk_buff、socket 双重锁、NAPI、syncookies 初始引入未确认；B3 只选 listener 的关键演进，未穷尽四种 steering 的所有历史；A3 不展开 io_uring ZC Rx ABI；D2 未确认所读 Seastar 版本具备与 Linux EDT 对等的完整 pacing。G2 对 Seastar native TIME_WAIT 的限制仅陈述已读代码，未做运行互通验证。详见 REPORT 与 OPEN-QUESTIONS。
