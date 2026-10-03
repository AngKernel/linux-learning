# P5 交付报告

已完成 20 个主题（A1–A3、B1–B3、C1–C4、D1–D4、E1–E2、F1–F2、G1–G2），以及 12 条跨主题原则总结。目录共 24 个 Markdown 文件：20 篇主题、principles、README、REPORT、OPEN-QUESTIONS。只修改 `notes/03-tcp-design/`，没有生成用户态 TCP 实现或提交第三方源码。

## 主要交付

- 内存与并发：区分 skb/数据所有权、forward allocation 与物理页、RCU 类型安全与对象身份、request 查找与 accept queue。
- 批处理与时间：核对 NAPI 两层预算、GSO 与硬件分段、TSQ/BQL/autocorking、busy poll、非级联时间轮、EDT/fq/内部 pacing、ACK 与 RTO。
- 扩展与安全：限定 CC ops、BPF 字段访问、ULP/kTLS 与 sockops；安全两篇比普通主题更详细，解释 cookie 条件、challenge ACK 共享预算、SACK 计数/资源放大及修复后进展回归。
- 成本与原则：G1 给出可解释的 perf 测量步骤；G2 将省掉的路径与移交的保证对应；principles 的 12 条原则每条有至少两个主题的具体证据。

## 证据与静态检查

核查日期：2026-10-03。Linux `git describe` 为 v6.18，非浅克隆；只使用已跟踪该版本代码。内核树既有未跟踪 notes 目录未修改、不参与依据。

使用 `rg` 定位符号，阅读上下文；用相关文件的 `git log -S`、`git blame` 和完整 `git show` 定位/核对演进。49 个不同的 12 位历史 hash 均已验证为 v6.18 的祖先，正文动机与历史数字已读取，数字保留原测试条件。自动检查 20 篇结构完整；134 处不同的内核源码引用做存在性/行号范围检查，再查看引用起始行并修正空行/偏移引用。

外部资料实际读取了固定版 lwIP/VPP/DPDK 官方资料、P6 固定源码、USENIX 2016 公开摘要与 Netflix 原始安全公告。NVD 页面返回空内容、GitHub 公告页面一度 503，未用它们作事实依据；公告改用实际访问成功的官方 raw 文件。论文只引用已读取摘要，没有声称读完全文。

最终完整分支使用 `git diff --check c51a94c..HEAD` 检查；这项仅证明差异文本没有 Git 检出的空白问题，不等于事实全部正确。目录/文件检查与关键引文抽查通过。全部验证属于静态检查，无性能或协议运行实验。

## 建议调度者抽查的三处

| 主题 | 当前源码位置 | 直接支持的结论 | 历史 commit |
|---|---|---|---|
| B2 | `net/ipv4/inet_hashtables.c:549` | 首次匹配→非零引用→再次匹配身份→必要时重试 | `3ab5aee7fe84`，Eric Dumazet；`5f0d5a3ae7cf`，Paul E. McKenney |
| C3 | `net/ipv4/tcp_output.c:1208` | TSQ 控制下层排队，6.18 恢复工作由 per-CPU BH work 执行 | `46d3ceabd8d9`，Eric Dumazet；`fd0406e5ca53`，Tejun Heo |
| F2 | `net/ipv4/tcp_input.c:1716` | 合并 skb 前同时限制 payload 上界和 16 位段计数 | `3b4929f65b0d`，Eric Dumazet |

可追加查 F2 的 `net/ipv4/tcp_ipv4.c:3628`（challenge ACK 共享限额默认 INT_MAX），和 F1 的 `net/ipv4/tcp_input.c:7542`（cookie 临时 request 释放）。这些是旧资料容易误述的地方。

## 未完成或未确认

1. 所有主题的运行期验证均未完成；未运行 v6.18 VM、编译内核、BPF selftest、perf 压测、NIC/devmem 测试或用户态栈。宿主 6.8 的结果不能替代目标，因此未包装成“实测”。
2. pre-Git 的 sk_buff、双重 socket 锁、NAPI、syncookies 最初引入未确认；已确认的是本文列出的后续关键演进。
3. B3 没有穷尽 RSS/RPS/RFS/XPS 全部历史；A3 没有展开 io_uring ZC Rx ABI；D2 未确认 Seastar 有与 EDT 对等的完整 pacing。本批要求中的主体机制已经覆盖。
4. 用户态对照为固定版本、选定路径核查，不是整个项目的安全/协议合规认证；G2 的 Seastar native TIME_WAIT FIXME 未做互通复现。
5. 文中历史性能数字未复测；部分原提交不提供完整硬件条件，已注明。不能把不同实验数字拼成统一收益曲线。
6. Mermaid 图已作源码关系检查，未运行渲染器验收；GitHub 风格引用 `路径:行号` 以本地 IDE/代码阅读为主。

## 后续关注点

建议 P9 分会话核对 A3（API/页与设备能力）、B（并发/回收）、C/D（预算与时钟/EDT）、E（BPF/ULP 上下文）、F（漏洞修复与默认行为）、G（统计口径）。优先 F、A3、D2/E，再安排运行实验。OPEN-QUESTIONS 汇总了环境、负载和硬件选择；本任务没有为这些选择中途停工。
