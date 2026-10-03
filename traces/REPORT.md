# P3 追踪库交付报告

本篇回答：追踪库覆盖哪些阶段、验证到什么程度？前置阅读：`README.md`、`SOURCES.md`。预计阅读时间：2 分钟。日期：2026-10-03。

## 已完成

- `rx-path.bt`：virtio IRQ handler、NET_RX、virtio RX poll、GRO、协议分发、IPv4 单包/list、TCP、socket 可读、任务唤醒尝试，共 11 个阶段；每阶段 kprobe 计数和 kretprobe 包围耗时直方图。
- `rx-smoke.bt`：GRO/TCP 两个计数，供完整自检使用。
- `irq.bt`：按 CPU、IRQ、handler 名字计数和耗时。
- `softirq-napi.bt`：每 CPU/vector 的 softirq 次数/耗时，每 NAPI 实例 work/budget 分布和满预算计数。
- `drop-reason.bt`：kfree_skb reason + location；明确不覆盖所有硬件/XDP 丢包。
- `function-graph.sh`：指定子树、深度限制、独立 instance、退出清理和 overrun 提示。
- `perf-rx.sh`：保留 softirq/NAPI 事件时间序列。
- `run.sh`：检查 guest 6.18、root、bpftrace ≥0.21、精确探针可用性；每个脚本都有观察对象、运行方式和预期输出注释。

所有函数都查过 v6.18 定义，非源码 inline。`napi_gro_receive` 是 inline，已换成 `gro_receive_skb`；IPv4 同时考虑 `ip_list_rcv`；TX NAPI 的零 work 不等于未回收完成项。

## 实际验证

Bash 语法、帮助入口、普通用户错误路径、内嵌 Python 语法、文档链接和源码引用检查通过。探针函数/字段逐项查过源码，详细位置在 `SOURCES.md`。BPF 文件分隔符检查仅是静态辅助，不能视作真实编译。

**尚无真实 guest BPF/ftrace/perf 输出。** 宿主没有 bpftrace，环境全流程在 pahole 缺失检查处停止；没有安装软件，也没有拿宿主 6.8 的观测冒充 6.18 结果。示例输出都只是格式说明。

## 未完成与注意事项

需在完整构建的 guest 核对每个探针是否因优化/配置变化不可用，运行 bpftrace parser/verifier、检查 kretprobe 漏失和观察开销；验证 function_graph 实例文件与 ring buffer overrun。当前统计包括 SSH/其他流量，`try_to_wake_up` 包含非网络唤醒，耗时不是每包端到端延迟；批处理、GRO、TX completion 的计数单位不能混用。

开放问题统一放在 `../env/OPEN-QUESTIONS.md`。P9 优先抽查上述三处容易沿用旧版本印象的点，再验证现有 BPF 语法和运行时输出。
