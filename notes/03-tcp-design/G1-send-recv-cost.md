# G1. 一次 send/recv：按工作来源测量，而不是先猜百分比

本篇回答：系统调用、拷贝、调度、cache 和锁的成本在哪？怎样用 perf 得到可解释的数据？前置阅读：A1–A3、B1、C1–C4。预计阅读：13 分钟。源码基准：Linux v6.18。

## 1. 问题

“内核栈慢在拷贝”或“慢在系统调用”都只是假设。小请求可能由固定入口成本主导，大流量可能由复制/内存主导，多线程共享 socket 可能由同步主导。缺少具体工作负载就没有可信的统一开销比例。

## 2. 约束

一次调用可能立刻成功、部分成功、睡眠或返回暂不可用；同一连接的 RX softirq 可能在另一个 CPU。应用线程的 CPU 时间不包括系统全部网络工作，系统级统计又会混入背景任务。主机上的 syscall、特权级切换与线程 context switch（上下文切换）不能当成同一计数。

## 3. 方案：先定位真实工作

| 工作 | 6.18 可定位的入口/分支 | 解释边界 |
|---|---|---|
| fd/参数/用户缓冲导入 | `net/socket.c:2209`，`__sys_sendto()` | `send()` 在此族路径转入协议，实际 syscall 依架构与 API |
| 安全/协议分派 | `net/socket.c:737`、`net/socket.c:1096` | LSM hook 与 socket ops；是否有额外策略由配置决定 |
| socket 同步 | `net/ipv4/tcp.c:1408`、`net/ipv4/tcp.c:2913` | `lock_sock()` 与 `release_sock()`，后者可能执行 backlog 工作 |
| 普通发送复制 | `net/ipv4/tcp.c:1272` | 用户字节复制到 skb page fragment，另有 ZC/splice 分支 |
| 普通接收复制 | `net/ipv4/tcp.c:2823` | 从可读 skb 复制到应用，devmem 等另走路径 |
| 等待空间/数据 | `net/ipv4/tcp.c:1366`、`net/ipv4/tcp.c:2777` | 可能睡眠并发生调度，不是每次 send/recv 必然如此 |
| 分配、引用与跨核释放 | A1、A2、B3 | 可以消耗 cache/bandwidth；不能从函数名直接量化 |

若 recv 队列为空，入口还可能先 busy poll（`net/ipv4/tcp.c:2922`），所以 CPU 高可能是主动换延迟。一次 send 成功通常只说明数据被接受，不保证全部上线路；按 syscall 时长计“端到端网络延迟”会测错对象。

## 4. 演进：缩短关键区，而不取消语义

| commit / 作者 | 动机 | 正文数据 |
|---|---|---|
| `2cd81161848d` / Arjun Roy | 拆出已持 socket 锁可调用的 `tcp_recvmsg_locked()`，为接收 ZC 小块复制复用路径。 | 该提交未提供性能数据。 |
| `f35f821935d8` / Eric Dumazet | recv 消费后延迟 skb 释放，减少持锁期间逐页释放与 backlog 积压，并改善分配/释放 CPU 局部性。 | 100G NIC，10 轮中单 TCP_STREAM 最大吞吐：MTU1500 55→66 Gbit/s；页大小 payload 场景 82→95 Gbit/s。不是平均吞吐或所有机器收益。 |

后者说明“free 看似与网络无关”也能决定连接处理性能；不能只盯复制指令。

## 5. 取舍

普通复制提供清晰的缓冲生命期；锁支持任意线程；调度和预算让其他任务运行；通用 hook 支持安全与策略。每层都可优化，但移除后必须说明谁承担原契约。cache miss 的 PMU 指标也只是相关证据，不能直接等价为某函数污染了 cache。

## 6. 用户态对照

Seastar 固定提交 `e417c0c0...` 同时存在 native 与 POSIX 网络后端；`src/net/native-stack.cc:147` 和 `src/net/posix-stack.cc:905` 是不同实现。[native 源码](https://github.com/scylladb/seastar/blob/e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b/src/net/native-stack.cc#L147)、[POSIX 源码](https://github.com/scylladb/seastar/blob/e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b/src/net/posix-stack.cc#L905) 应用用了 future/单核 reactor，不能证明它已经绕过内核 TCP。

## 7. 验证：一个能复查的 perf 测量流程

以下命令未在目标 6.18 运行；需要已有受控测试程序和 `perf`。不编写协议栈或新性能测试实现。先记录内核、CPU/NUMA、MTU、offload、qdisc、CPU 亲和性、并发数、消息大小、有效传输字节与完整性检查，再进入稳定测量阶段。

```bash
# 先用实际测试进程 PID 替换示例值
APP_PID=12345
perf list
perf stat -p "$APP_PID" -e task-clock,context-switches,cpu-migrations,cycles,instructions,cache-misses -- sleep 10
sudo perf stat -a -e cycles,instructions,context-switches -- sleep 10
sudo perf record -a -g -o /tmp/tcp-design-perf.data -- sleep 10
sudo perf report --stdio -i /tmp/tcp-design-perf.data
```

语法根据 `tools/perf/Documentation/perf-stat.txt:73`、第 123 行与 `tools/perf/Documentation/perf-record.txt:235`、第 294 行核对。进程级与系统级应在相同稳定负载的匹配运行中比较；若直接并行多组硬件计数器，要查看 multiplex 比例。VM 中事件不支持就记录缺失，不能把零计数当零成本。

按以下顺序回答假设：

1. **固定成本**：同样有效吞吐，改变调用块大小，比较 calls/byte、cycles/byte。用实际 `perf list` 暴露的 syscall tracepoint 计数；不要用固定时长直接比较传输量不同的两组 cycles。
2. **复制与内存**：结合调用栈寻找复制/分配/释放热点，再比较相同完整数据消费语义的普通与 ZC 路径。截断接收可人为省掉 payload 工作，不能当等价结果。
3. **调度**：context-switches 增长提示发生切换，结合线程等待和吞吐看原因；syscall 次数不等于切换次数。低切换也可能是一直 busy poll。
4. **锁与 backlog**：看 `release_sock/__release_sock` 调用栈。它们的样本包括代收包工作，不全是锁等待；需要进一步的锁/调度分析才能归因。
5. **cache 与跨核**：固定负载再改变绑核、队列映射，比较 cycles/byte 和 PMU 趋势；hardware cache-misses 不直接说明是哪一层缓存或是否为共享锁造成。

至少重复 3 次，报告变化范围、有效数据量、p50/p99 和 CPU，而非只挑最好的一次。采样、调用栈展开与 tracepoint 本身有扰动；CPU 样本反映 on-CPU 分布，不直接包含睡眠墙钟时间。实验 artifact 保存在目标测试目录，不提交原始含地址/业务数据的 trace 到本篇。

## 要点回顾

- 没有负载条件，就没有统一的开销百分比。
- syscall 不等于线程切换，进程统计不等于系统总成本。
- free、backlog 和跨核局部性也可能主导。
- 一次只改一个因素，并归一到有效字节或完成请求。

## 自测

1. 每次 send 都一定发生线程切换吗？
2. recv 的 release_sock 热点是否全是锁竞争？
3. 只看应用 PID 的 cycles 能算整个 RX 成本吗？
4. 为什么零拷贝基准必须核对接收端是否完整消费？

<details><summary>答案</summary>

1. 不一定。2. 不是，可能在处理 backlog。3. 不能，softirq 等工作可能在其他上下文/CPU。4. 截断可省掉本应比较的 payload 工作，使两组语义不同。

</details>

## 与 DPDK/VPP 的对照

cycles/packet 与 vector size 的经验有用，但 TCP 的有效字节、ACK、重传和应用完成请求数也要对齐。把空轮询 CPU 排除后再称“用户态成本更低”，会漏掉体系的一部分真实代价。
