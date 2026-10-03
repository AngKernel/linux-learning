# A2. socket 内存：额度不是一池预分配物理页

本篇回答：每连接额度如何减少记账成本？全局和租户压力如何限制增长？前置阅读：A1、内存与 cgroup 基础。预计阅读：10 分钟。源码基准：Linux v6.18。

## 1. 问题

若只按 TCP payload 字节限流，许多小 skb 就能消耗大量元数据；若每次分配都更新全局计数，多核又会争用同一 cache line。还必须防止一个连接或租户占完内存。

## 2. 约束

既要让小连接有进展机会，也不能让攻击者靠创建很多“最低保证”连接绕过硬限制。协议全局用量与 memcg（内存控制组）用量的作用域不同，网络 namespace 也不自动意味着所有 TCP 预算独立。

## 3. 方案

| 字段或配置 | 含义和单位 | v6.18 证据 |
|---|---|---|
| `sk_forward_alloc` | 已记账、尚可消费的字节额度；不是专属物理页池 | `include/net/sock.h:463`、`net/core/sock.c:3365` |
| `sk_wmem_queued` / `sk_rmem_alloc` | 发送持久队列 / 接收内存记账；不能按应用有效字节理解 | `include/net/sock.h:472`、`include/net/sock.h:414` |
| `tcp_mem` | 全局 TCP 记账阈值 min/pressure/max，单位为页 | `net/ipv4/tcp.c:305`、`Documentation/networking/ip-sysctl.rst:639` |
| `tcp_rmem` / `tcp_wmem` | 接收/发送缓冲参数，单位为字节 | `Documentation/networking/ip-sysctl.rst:828`、`Documentation/networking/ip-sysctl.rst:1180` |

`__sk_mem_schedule()` 将请求换算为页并增加 forward allocation，准入失败则回滚（`net/core/sock.c:3365`）。`sk_mem_charge()` 消费额度；解除记账再归还，达到可回收粒度时回收（`include/net/sock.h:1586`）。`SO_RESERVE_MEM` 的保留额度路径也参与这里的回收计算；它仍不是“预先分配一块能直接写的发送内存”。

`__sk_mem_raise_allocated()` 先做协议和 memcg 记账，再处理低水位、压力和上限（`net/core/sock.c:3251`）。最低缓冲保证不允许普遍绕过硬限；低于平均用量可增长的启发式只适用于全局压力。发送侧还有为取得进展而强制记账的特殊分支，不能把 max 理解为绝不短暂越过的物理内存墙。

接收压力下，`tcp_prune_queue()` 会尝试压缩存储、清理乱序数据，必要时拒绝新包，见 `net/ipv4/tcp_input.c:5762`。压缩、重传和吞吐下降是资源约束的代价；TCP 可靠性允许重传，不保证所有到达数据都被无条件保留。

## 4. 演进

| commit / 作者 | 动机 | 正文数据 |
|---|---|---|
| `3cd3399dd7a8` / Eric Dumazet | 引入 per-CPU 全局记账缓存，减少共享计数争用。 | 缓存范围 ±1 MB；该提交未提供吞吐/延迟性能数据。 |
| `4890b686f408` / Eric Dumazet | 尽快回收 socket 未使用额度，以 per-CPU 缓存抵消更频繁更新。 | 举旧实现每连接 2 MB、10000 连接可保留 20 GB 的额度估算；不是实际物理页测量。该提交未提供性能数据。 |

这些是优化已有记账设计，不是 socket 内存管理的首次引入。复查：`git log -S 'sk_forward_alloc' -- net/core/sock.c`，再 `git show <hash>`。

## 5. 取舍

额度批处理降低共享写入，却使即时用量不等于所有 CPU、所有 socket 的精确同步总和。多层限制提高隔离能力，也增加判断和故障定位成本。压力下压缩队列把内存问题变成 CPU 与尾延迟问题；盲目加大缓冲又会让单连接积压更多。

## 6. 用户态对照

lwIP 2.2.0 同时配置 `TCP_SND_BUF` 字节额度和 `TCP_SND_QUEUELEN` pbuf 数量，也能限制乱序队列。部署可用固定上限换可预测内存，但应用仍需处理资源耗尽。[固定版本 opt.h](https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_2_0_RELEASE/src/include/lwip/opt.h)

## 7. 验证

目标 VM 中先读 `sysctl net.ipv4.tcp_mem net.ipv4.tcp_rmem net.ipv4.tcp_wmem`，用 `ss -mti` 观察受控流量下的 socket 内存，再对照 `perf` 中队列压缩热点。`ss` 展示多个不同语义的计数，不应相加当物理页总量。本篇未运行压测，也未修改宿主全局阈值。

## 要点回顾

- forward allocation 是记账预算；不能直接当页池。
- 资源控制同时考虑连接、协议和租户。
- 内存压力有 CPU、重传和延迟代价。

## 自测

1. `tcp_mem` 与 `tcp_rmem` 单位是否相同？
2. 最低额度能否保证任意多连接都成功分配？
3. 减少队列占用为什么可能增加 CPU？

<details><summary>答案</summary>

1. 前者页，后者字节。2. 不能；否则可绕过硬限造成 DoS。3. 扫描、合并与复制队列数据本身要工作，还可能触发后续重传。

</details>

## 与 DPDK/VPP 的对照

DPDK mempool 的对象可直接分配，和 `sk_forward_alloc` 账面额度并不等价。二者都需防止单流吃光容量；应用专用池能简化策略，但跨租户公平、失败恢复要由系统设计者补上。该对照是由 A1 与本篇资源语义推导的设计判断。
