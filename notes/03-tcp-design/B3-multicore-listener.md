# B3. 多核扩展：分散包、靠近应用、拆开监听共享状态

本篇回答：RSS/RPS/RFS/XPS 分别选什么？SO_REUSEPORT 与无锁 listener 解决哪种竞争？前置阅读：B1、B2、网卡队列与 RSS。预计阅读：12 分钟。源码基准：Linux v6.18。

## 1. 问题

多队列只解决部分分流。网卡、协议处理 CPU、应用线程和 TX completion 可能落在不同核；连接都到同一个 listener 时还会争用共享状态。

## 2. 约束

应用线程可迁移，硬件队列有限；保持流内顺序比瞬时平均分流更重要。内核还须支持共享一个监听 fd、独立监听 socket 和不同设备能力。

## 3. 方案

| 机制 | 主要选择对象 | v6.18 文档 |
|---|---|---|
| RSS（接收端扩展） | NIC 接收队列，由硬件 hash/映射分流 | `Documentation/networking/scaling.rst:24` |
| RPS（接收包导向） | 后续协议处理 CPU，软件转交输入队列 | `Documentation/networking/scaling.rst:173` |
| RFS（接收流导向） | 倾向应用消费数据所在 CPU，并考虑旧队列进度以免乱序 | `Documentation/networking/scaling.rst:311` |
| XPS（发送包导向） | TX 队列，可用 CPU 或 RX 队列映射 | `Documentation/networking/scaling.rst:461` |

`SO_REUSEPORT` 让多个 listener 分享地址端口并选择其中一个，降低共享 accept 入口竞争；它不自动保证应用绑定正确 CPU，也不把一个既有连接的数据任意散给所有 listener。

listener 可扩展性还有另一条线：把握手的 `request_sock` 放进 ehash，握手 ACK 可直接找到它。6.18 的 `reqsk_queue_hash_req()` 调用 `inet_ehash_insert()`，见 `net/ipv4/inet_connection_sock.c:1170`。`tcp_v4_rcv()` 对 LISTEN 直接走 `tcp_v4_do_rcv()`，绕过下面的普通 socket 锁（`net/ipv4/tcp_ipv4.c:2363`）。

“无锁 listener”是缩小某把锁的作用范围，不是没有同步。child 进入 accept queue 仍拿 `rskq_lock`（`net/ipv4/inet_connection_sock.c:1400`）；ehash 写端也有同步。request 的查找位置与完成连接的 accept 队列位置是不同问题。

## 4. 演进

| commit / 作者 | 动机 | 正文数据 |
|---|---|---|
| `079096f103fa` / Eric Dumazet | SYN_RECV request 移入 ehash，握手 ACK 不再先找并锁 listener。 | 正文称正常情况下 listener 锁压力减半；没有配套 benchmark，不能当吞吐翻倍。 |
| `e994b2f0fb92` / Eric Dumazet | 前置状态拆分完成后，SYN 处理不再持 listener socket 锁。 | 测试 3.5 Mpps SYN flood 且 CPU 有余量；未给完整平台与修改前基线。 |

以上是监听扩展关键节点，不是 RSS 等机制的引入记录。RSS/RPS/RFS/XPS 的详细逐项历史留给后续专题；当前作用和配置以 6.18 的 scaling 文档为准。定位 request 改造可用 `git log -S 'reqsk_queue_hash_req' -- net/ipv4/inet_connection_sock.c`。

## 5. 取舍

更多分流减少某一共享点，也增加核间转交、映射配置和调优维度。RPS 可能在硬件分流充分时增加 IPI/cache 开销；RFS 的局部性目标可能和均匀负载冲突。拆状态后容易遗漏原来依赖 listener clone 隐式继承的初始化；不能只删除锁而不重审所有权。

## 6. 用户态对照

VPP 25.02 把 RX 队列分配给 worker，并允许配置 CPU 亲和性；可在部署期确定处理者。[官方多线程说明](https://docs.fd.io/vpp/25.02/developer/corearchitecture/multi_thread.html) 推论：当应用与流归属也受控时，可减少 Linux 为任意线程迁移付出的协调。重流热点、跨 worker 交接和应用进程与 transport worker 的分离仍需考虑。

## 7. 验证

目标环境先记录队列数、IRQ 亲和性、RSS indirection 和 worker/应用绑核，再一次只改一个导向因素。分别测长流吞吐、短连接 CPS、p99 和各 CPU 利用率；SYN 处理能力不能替代成功 accept 的能力。此实验未运行，不能套用历史 flood 数字作为当前容量。

## 要点回顾

- 四种导向选择的对象不同。
- request 查表和 accept 排队必须分开理解。
- 扩展常靠拆分状态与减少共享写入，不只是增加锁数量。

## 自测

1. RSS 直接决定应用线程吗？
2. 无锁 listener 是否取消 accept queue 锁？
3. request 放进 ehash 为何减少 listener 压力？

<details><summary>答案</summary>

1. 否，它选择接收队列。2. 否，队列仍有专门锁。3. 后续握手 ACK 可直接定位 request，无需先经 listener 找它。

</details>

## 与 DPDK/VPP 的对照

DPDK 的 RSS 与 RX queue/worker 映射是熟悉的起点；Linux 还允许应用任意迁移，并独立调度设备、协议和进程。固定 worker 能简化这些自由度，却要求部署与应用承担流归属规划。
