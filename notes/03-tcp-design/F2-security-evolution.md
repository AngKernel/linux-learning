# F2. 漏洞怎样改变 TCP 设计：共享状态侧信道与元数据放大

本篇回答：CVE-2016-5696 的限速为何泄漏信息？2019 年 SACK 问题分别怎样修？为何补丁还需兼容性修正？前置阅读：A1、A2、C2、D3、F1。预计阅读：18 分钟。源码基准：Linux v6.18；本篇讲历史根因与当前防线，不声称 6.18 仍存在这些旧缺陷。

## 1. 问题：合法机制的组合也会制造攻击面

challenge ACK（质询确认）原本用于提高连接对异常 RST/SYN/ACK 的稳健性；SACK（选择确认）帮助发送端定位缺口，减少重传。安全问题不一定来自遗漏一个包长检查，也可能来自共享预算、计数单位和极端合法参数组合。

CVE-2016-5696 的研究公开页说明，off-path（不在通信路径上的）攻击者能借共享限速反馈推断连接及序列信息，进而干扰连接。[USENIX 2016 论文公开摘要](https://www.usenix.org/conference/usenixsecurity16/technical-sessions/presentation/cao) 本篇读取了该摘要与本地修复提交，未把未阅读全文的论文细节当证据。

Netflix 2019 公告分别列出整数溢出的 SACK Panic、重传队列碎片化资源放大、极小 MSS 的额外开销，不能把它们当作同一个崩溃。[原始公告](https://raw.githubusercontent.com/Netflix/security-bulletins/master/advisories/third-party/2019-001.md)

## 2. 约束：防滥用措施不能破坏其他连接的隔离与进展

全局限速可减少回复放大，却使不相关连接争同一预算；固定字节限额控制 payload，却可能漏掉由对端 ACK 决定的内部 skb 数量。修复必须仍允许真实丢包时的队列拆分、低缓冲配置和合理 MSS，而不是把所有慢路径一概禁止。

## 3. 方案：按三类不变量分析

### 3.1 challenge ACK：共享限额产生跨连接反馈

原始问题可以抽象成：连接 A 的异常输入消耗共享 challenge ACK 预算，攻击者在自己可观测的连接 B 上观察剩余额度，借此区分 A 的状态。无需读取 A 的包内容，共享资源也能变成信息通道。这是从修复动机和论文摘要归纳的机制解释，不是利用步骤。

6.18 的 `tcp_send_challenge_ack()` 先用 socket 的 `last_oow_ack_time` 做单连接速率检查，然后才考虑网络 namespace 级预算（`net/ipv4/tcp_input.c:3822`）。当 `tcp_challenge_ack_limit=INT_MAX` 时直接跳过该共享额度；默认赋值在 `net/ipv4/tcp_ipv4.c:3628`。

若管理员主动设有限共享额度，当前代码仍对每秒额度随机化，但作用域内的连接仍会共享状态。`Documentation/networking/ip-sysctl.rst:1257` 明确说明这可能允许侧信道，默认无限；不能沿用老教程的“默认每主机 100 次”或“1000 次”描述。

质询本身没有取消。当前异常 RST/SYN 验证仍调用它，见 `net/ipv4/tcp_input.c:6186`、第 6216 行。所谓共享限额默认关闭，关闭的是这层预算，不是关闭 TCP 对异常包的验证，也不是取消每 socket 速率约束。

### 3.2 CVE-2019-11477：payload 少不代表段计数小

TCP 在 SACK 处理中会把部分重传队列的数据重新合并。低 MSS 意味着同样 payload 对应更多段；合并若只看可容纳多少 fragment，却不看 `tcp_gso_segs` 的 16 位表示范围，就可能溢出并破坏后续不变量。

6.18 的 `tcp_skb_shift()` 在 `net/ipv4/tcp_input.c:1716` 同时检查合并后长度与段数：

```c
if (unlikely(to->len + shiftlen >= 65535 * TCP_MIN_GSO_SIZE))
    return 0;
if (unlikely(tcp_skb_pcount(to) + pcount > 65535))
    return 0;
```

`TCP_MIN_GSO_SIZE` 在 `include/net/tcp.h:74` 定义。检查不仅基于当前 MSS；即使后续按更小 MSS 重分段，也不能溢出表示范围。这是数据表示上限约束，不是单纯把一个计数器扩大就结束。

### 3.3 CVE-2019-11478/11479：对象和处理次数的放大

11478 的核心是对端反馈诱导重传队列拆成许多小 skb，使元数据和处理成本远超原 payload。早期链表实现还会放大遍历。6.18 的 `tcp_fragment()` 根据 `sk_wmem_queued/sk_sndbuf` 限制继续拆分，并保留写队列与重传队列头尾等进展例外（`net/ipv4/tcp_output.c:1756`）。拒绝拆分时记 `TCPWqueueTooBig`，不意味着所有触发都来自攻击。

11479 则强调过小 MSS 带来很高的包头、CPU 与 NIC 每段开销；不是一定需要 SACK 才会发生。`tcp_min_snd_mss` 提供策略下限，参与 `__tcp_mtu_to_mss()`（`net/ipv4/tcp_output.c:1928`）。6.18 默认仍为 48，定义与初始化在 `include/net/tcp.h:73`、`net/ipv4/tcp_ipv4.c:3581`；默认兼容性不等于任意部署的最佳防护阈值。MSS/选项/实际 payload 三个长度不能混算。

## 4. 演进：初次止血之后，继续缩小副作用

| commit / 作者 | 改了什么与动机 | 正文性能数据 |
|---|---|---|
| `75ff39ccc1bd` / Eric Dumazet | 对 2016 侧信道提高并随机化共享 challenge ACK 额度，提高推断成本。 | 该提交未提供性能数据。不是证明侧信道根因被彻底消除。 |
| `79e3602caa6f` / Eric Dumazet | 共享限额改按 netns，默认关闭，减少跨连接侧信道。 | 该提交未提供性能数据。 |
| `3b4929f65b0d` / Eric Dumazet | 修 11477：限制 SACK 合并 payload 和段数，保护 16 位计数。 | 该提交未提供性能数据；给出触发原理和崩溃不变量。 |
| `f070ef2ac667` / Eric Dumazet | 修 11478：限制 `tcp_fragment()` 引起的内存放大。 | 该提交未提供性能数据。 |
| `5f3e2bf008c2` / Eric Dumazet | 应对 11479：提供可配置 MSS 下限，同时保留兼容默认值。 | 该提交未提供性能数据。 |
| `b6653b3629e5`、`b617158dc096` / Eric Dumazet | 修正初始拆分限额对小 SO_SNDBUF、丢包重传的回归；保留写队列和头尾拆分的进展机会及容量余量。 | 两提交均未提供性能数据。 |

这些 hash 均在本地 v6.18 可达历史读取了完整正文。`git blame -L 1716,1728 -- net/ipv4/tcp_input.c` 可直接追到 11477 的边界检查。历史补丁行文中的原始阈值不能覆盖当前经过后续修正的判断。

## 5. 取舍：安全边界也是进展边界

- 限速太共享，可能泄漏状态；完全不限制异常回复又会付出 CPU/带宽。作用域与随机化回答不同问题。
- 禁止拆分能阻止资源放大，但若阻止正常重传进展，防护本身就制造拒绝服务。当前例外有明确历史原因。
- 提高 MSS 下限能降低每字节包处理成本，也可能损害确需较小 MSS 的路径；它是部署策略，不是替代整数/内存检查的万能修复。
- 关闭 SACK 是当年某些受影响环境的缓解选择，却损失正常丢包恢复能力。本文不建议在已修复的 6.18 上因旧公告而直接关闭功能。

审计时应为每个量标单位：payload 字节、skb `truesize`、GSO 段数、链节点数、每秒预算。攻击者常利用的正是这些量并不成固定比例。

## 6. 用户态对照

lwIP 2.2.1 的 `LWIP_TCP_SACK_OUT` 配置说明是“发送 SACK”，`rcv_sacks[]` 也有明确数量上限，见 `src/include/lwip/opt.h:1325`、`src/include/lwip/tcp.h:288`。[固定配置源码](https://github.com/lwip-tcpip/lwip/blob/77dcd25a72509eb83f72b033d219b1d40cd8eb95/src/include/lwip/opt.h#L1325) 不能仅凭 SACK 这个名字，推导它复制 Linux 发送端 SACK scoreboard/GSO 合并路径或受相同 CVE 影响。本篇没有对用户态栈做完整漏洞审计；对共享限额、计数单位和资源放大的设计问题仍应检查。

## 7. 验证：核对防线，不在宿主重放攻击

本篇只做源码/历史检查，没有漏洞复现。可在目标 VM 读取 `tcp_challenge_ack_limit`、`tcp_min_snd_mss`，确认与源代码默认值是否被部署配置覆盖；阅读当前 `tcp_skb_shift()` 和 `tcp_fragment()` 的完整条件，确认不只摘第一版补丁。

`nstat -az` 的 TCPChallengeACK 与 TCPWqueueTooBig 名称在 `net/ipv4/proc.c:258`、第 294 行；观察前后差值仅证明相应分支发生，不能自动判定被攻击。需要运行回归时应加入“正常小缓冲 + 丢包仍能进展”的正例，而不只验证异常输入被拒绝。运行期回归留待目标 6.18 VM。

## 要点回顾

- 共享资源既有性能代价，也可能形成侧信道。
- 长度、对象数与段计数都必须有独立边界。
- 安全修复需证明正常连接仍能前进。
- 当前实现必须结合初始修复与后续回归修正阅读。

## 自测

1. 默认跳过共享 challenge ACK 限额，是否等于不再发 challenge ACK？
2. 11477 为什么不能只按单个 `send()` 大小判断安全？
3. 11478 的修复为何允许某些 skb 继续拆分？
4. lwIP 能发 SACK，能否直接认定存在 Linux 的 SACK Panic 路径？

<details><summary>答案</summary>

1. 不是，质询与 per-socket 限速仍在。2. 后续 SACK 合并可改变数据表示和段数。3. 避免小发送缓冲/丢包时阻止可靠传输进展。4. 不能，必须查具体数据结构与处理路径。

</details>

## 与 DPDK/VPP 的对照

无锁、固定池和大 burst 都不会自动免疫整数溢出或资源放大。用户态隔离可缩小某些崩溃影响范围，但设备、CPU、共享队列仍可能影响邻居；需要验证的是协议不变量和资源作用域，而不是代码运行在哪个特权级。
