# E1. 拥塞控制 ops：把策略变成受约束的插件

本篇回答：CUBIC/BBR 如何接入同一 TCP？BPF struct_ops 能换掉什么，不能保证什么？前置阅读：D2、D3、拥塞控制基础。预计阅读：10 分钟。源码基准：Linux v6.18。

## 1. 问题

不同路径适合不同拥塞策略。若每种算法复制整套 TCP，ACK、重传、socket 生命周期就难以维护一致；若只能修改内核核心，部署新算法又很慢。

## 2. 约束

算法需要访问拥塞状态与反馈，但不能任意破坏内存和生命周期。已有应用应继续用 socket API；模块卸载、默认策略与每连接选择需要有明确边界。可插拔不意味着任意算法都公平或稳定。

## 3. 方案

`tcp_congestion_ops` 是拥塞控制操作表，见 `include/net/tcp.h:1230`。连接通过 `icsk_ca_ops` 指向算法，用 `icsk_ca_priv` 保存私有状态（`include/net/inet_connection_sock.h:91`、第 135 行）。注册检查必需的 `ssthresh`、`undo_cwnd`，以及 `cong_avoid/cong_control` 至少一个，见 `net/ipv4/tcp_cong.c:77`。

CUBIC 注册 `cong_avoid` 等回调（`net/ipv4/tcp_cubic.c:478`）；BBR 用 `cong_control`（`net/ipv4/tcp_bbr.c:1143`），可依据 delivery-rate 样本更新 rate/cwnd。`tcp_cong_control()` 在两种接口间分流，见 `net/ipv4/tcp_input.c:3638`。BBR 的模型动机和窗口/速率公式直接写在 `net/ipv4/tcp_bbr.c:1`，不能从“模块名 bbr”猜成其他版本的 BBR 算法。

BPF struct_ops（由 BPF 提供结构体函数操作）让程序实现这张表并通过相同注册路径接入。`net/ipv4/bpf_tcp_ca.c:61` 列出可写字段及边界，例如 pacing rate、cwnd 与私有区；不是把任意内核指针开放给程序。第 240 行最终调用 `tcp_register_congestion_control()`。验证器和类型约束保护执行边界，不证明算法的网络公平性、收敛或业务收益。

## 4. 演进

| commit / 作者 | 动机 | 正文性能数据 |
|---|---|---|
| `317a76f9a44b` / Stephen Hemminger | 引入可插拔拥塞控制，可内建或模块化，以 Reno 为起点/退路。 | 该提交未提供性能数据。 |
| `0f8782ea1497` / Neal Cardwell | 引入 BBR，按带宽和最小 RTT 建模，针对丢包型控制在不同网络中的问题。 | 仿真 10 Mbit/s、40 ms RTT、1000 包缓存、120 秒 TCP_STREAM，两算法均跑满，BBR 中位 RTT 43 ms、CUBIC 1.09 s；仅该条件的历史结果。 |
| `0baf26b0fcd7` / Martin KaFai Lau | TCP CC 成为首个 BPF struct_ops 使用者，加快算法试验并复用内核 TCP。 | 该提交未提供性能数据。 |

BBR 最初提交要求 fq；D2 的后续内部 pacing 已改变这一限制，不能把初始 commit 的 NOTE 当 6.18 的完整要求。

## 5. 取舍

策略共享可靠传输核心，减少重复实现；回调、私有状态和可用算法管理增加复杂度。BPF 加快更新不免除回归验证：乱序、应用受限、ECN、恢复与混合算法公平性都可能改变行为。

## 6. 用户态对照

VPP v25.06（`1573e751c5478d3914d26cdde153390967932d6b`）也有 `tcp_cc_algorithm_t` 和注册函数，ACK/loss/pacing 通过操作表分派，见 `src/vnet/tcp/tcp_cc.h:21`、`src/vnet/tcp/tcp.c:91`。[固定源码](https://github.com/FDio/vpp/blob/1573e751c5478d3914d26cdde153390967932d6b/src/vnet/tcp/tcp_cc.h#L21) 插件化的收益继续成立；用户态可直接更新进程库，但失去内核 BPF 的那一层受限访问验证。

## 7. 验证

先读取 `net.ipv4.tcp_available_congestion_control` 与 `tcp_congestion_control`，确认目标内核实际构建/加载的算法。源码自带 `tools/testing/selftests/bpf/progs/bpf_cubic.c` 与 `prog_tests/bpf_tcp_ca.c` 可核对框架用法；本任务不写算法实现，也未编译运行这些测试。性能对比要固定链路、RTT、丢包、并发和 qdisc。

## 要点回顾

- ops 分离策略与可靠传输机制。
- CUBIC 与 BBR 接口使用方式不同。
- BPF 验证通过不等于控制算法正确。

## 自测

1. 换拥塞模块是否换掉整个 TCP？
2. BPF CC 能任意写 socket 内存吗？
3. 历史 BBR 要求 fq 是否足以描述 6.18？

<details><summary>答案</summary>

1. 否，只替换约定范围内策略。2. 不能，有类型和字段访问限制。3. 不足，后续加入内部 pacing。

</details>

## 与 DPDK/VPP 的对照

VPP 的函数表模式很熟悉；内核还要处理模块/程序生命周期、每连接策略选择和不可信加载边界。数据面插件执行快，不自动意味着跨流公平性或拥塞稳定性已验证。
