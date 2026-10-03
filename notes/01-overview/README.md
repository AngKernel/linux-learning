# Linux 网络栈全景地图

本目录回答：一次 TCP 请求经过哪里、关键对象如何连接、安全逻辑挂在哪里、配置如何进入内核，以及接下来如何读源码。前置：C/C++ 与 TCP/网卡队列基础；内核执行上下文可结合 `../00-kernel-basics/` 补读。预计完整阅读约 2 小时，术语表按需查阅。

源码统一基于 `/home/chen/code/linux-lab/src/linux-6.18` 的 `v6.18`；已在开始和验收阶段实际运行 `git describe --always --dirty --tags` 确认。这里停留在模块、对象和边界，不展开逐个函数的实现。

## 文件与建议顺序

| 顺序 | 文件 | 内容 |
|---|---|---|
| 1 | [01-request-journey.md](01-request-journey.md) | 从建连、发请求到收响应的故事与时序图 |
| 2 | [02-layered-architecture.md](02-layered-architecture.md) | 分层职责、接口、socket 与两张操作表 |
| 3 | [03-core-objects.md](03-core-objects.md) | 八个核心对象的关联图、创建与回收边界 |
| 4 | [04-hook-map.md](04-hook-map.md) | XDP、tc/TCX、netfilter、socket/BPF 扩展及安全场景 |
| 5 | [05-control-plane.md](05-control-plane.md) | iproute2、rtnetlink、FIB、邻居和 sysctl |
| 6 | [06-source-map.md](06-source-map.md) | 源码规模实测与三档阅读范围 |
| 随查 | [07-glossary.md](07-glossary.md) | 110 个术语，一句话解释与后续章节定位 |
| 7 | [08-learning-dependencies.md](08-learning-dependencies.md) | 学习依赖图、八站学习顺序和实验验收问题 |
| 配套 | [count-source-lines.py](count-source-lines.py) | 只读统计已跟踪 C/H 文件的 `wc -l` 脚本 |
| 配套 | [SOURCE-STATS.tsv](SOURCE-STATS.tsv) | 本次实际执行的原始规模统计 |
| 管理 | [REPORT.md](REPORT.md) | 本任务完成情况、验证与限制 |
| 管理 | [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md) | 后续实验和事实核查需要确定的范围 |

首次快速建立地图可读 01 → 02 → 03 → 08，再按问题补 04–07。网络安全方向优先细读 04；已有设备收发经验的读者把重心放在对象生命周期、字节流与异步事件。

## 完成状态与边界

八篇正文均已完成，并附要点回顾、自测折叠答案和 DPDK/VPP 对照。统计脚本已实际执行；目录总行数包含注释和空行，父子目录统计不能相加。

运行时网络实验、规则挂载和抓包均未执行，文中明确区分观察任务与实测结果。Mermaid 已做代码块与语法人工检查，未在渲染器中验证。IPv4 TCP 普通以太网主线已核对；IPv6、bridge、隧道、硬件卸载及多次再入只标位置与边界，不宣称覆盖它们的全部顺序。

本篇不承诺网卡支持某种 XDP 模式、不指定机器默认参数，也不把 page pool 写成所有驱动必经设施。对跨目录章节使用稳定目录定位，待其他任务合并后由总索引整合。

## 要点回顾

- 先有路径图与对象图，再进入函数细节。
- 区分源码事实、位置推导的选型建议和未执行实验。
- 核心目标是为用户态 TCP 设计建立可验证的概念依赖。

## 自测题

1. 想知道 socket 与 sock 的区别，应先看哪两篇？
2. 为什么 `SOURCE-STATS.tsv` 不能证明网络栈的运行开销？
3. 想确认某驱动 native XDP 能力，是否能仅据 04 篇下结论？

<details>
<summary>答案</summary>

1. 02 的接口关系与 03 的对象生命周期。
2. 它只是固定口径的源码物理行数。
3. 不能；必须再核实实际驱动、硬件、配置与挂载结果。

</details>

## 与 DPDK/VPP 的对照

地图复用你熟悉的包、队列、查表和接口概念，重点补上 Linux 应用接口、TCP 连接状态、时间事件和跨层对象寿命。类比只用于定位，不代替各自的并发与所有权规则。
