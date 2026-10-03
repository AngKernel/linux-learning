# D4. TIME_WAIT 与 minisock：保留协议记忆，释放不再需要的状态

本篇回答：连接关闭后为何还保留状态？为何不用完整 tcp_sock？前置阅读：四次关闭、B2、D1。预计阅读：10 分钟。源码基准：Linux v6.18。

## 1. 问题

应用关闭不意味着网络中的旧报文消失。若立即遗忘旧连接，迟到数据可能干扰相同四元组的新连接，对端重传 FIN 也无法按旧状态响应。但短连接每次都保留完整发送/接收状态又浪费内存。

## 2. 约束

需保留身份、序列号与时间戳等防旧报文信息，同时控制存量和查找成本；关闭路径还可能遇到内存不足。TIME_WAIT 不是应用仍有活 fd 的同义词。

## 3. 方案

`inet_timewait_sock` 保留公共查找头和回收 timer（`include/net/inet_timewait_sock.h:33`）；`tcp_timewait_sock` 加上 TCP 所需字段（`include/linux/tcp.h:559`）。它是专用紧凑对象，不再保留完整 `tcp_sock` 的全部队列与控制状态。

`tcp_time_wait()` 分配紧凑对象，把 `rcv_nxt/snd_nxt`、接收窗口、最近时间戳等复制过去，再切换散列表归属并结束原 socket，见 `net/ipv4/tcp_minisocks.c:328`。状态已经移交后不能继续任意访问 tw 裸指针，函数注释有明确边界。

后续报文经 `tcp_timewait_state_process()` 检查并回应（`net/ipv4/tcp_minisocks.c:101`）。真正 TIME_WAIT 使用 `TCP_TIMEWAIT_LEN`，6.18 为 `60*HZ`（`include/net/tcp.h:141`）；这不等于所有 FIN_WAIT2 情况都固定 60 秒。每个 tw 的普通 timer 到期触发回收，见 `net/ipv4/inet_timewait_sock.c:172`。

分配失败会记溢出并直接结束原连接（`net/ipv4/tcp_minisocks.c:387`）：通用栈在资源耗尽时也必须做有损退让，不能承诺无限保留所有协议记忆。

## 4. 演进

| commit / 作者 | 动机 | 正文数据 |
|---|---|---|
| `8feaf0c0a548` / Arnaldo Carvalho de Melo | 泛化已有 TCP TIME_WAIT 对象与查找基础设施，让协议共享实现。 | 当时示例 slab 对象 TCPv4 96 B、TCPv6 128 B；不能当作 6.18 大小。未给吞吐性能数据，也非 minisock 最初引入。 |
| `789f558cfb36` / Eric Dumazet | 去掉集中式 TIME_WAIT 专用回收调度，改为每对象 timer 分散负载。 | 当时每对象多 64 B，200 路 TCP_CC 约 42–44 万→80–81 万，ping 最大延迟从 25–33 ms 降至 0.36 ms；测试启用了已过时的 recycle 条件，不应照抄到 6.18。 |

第二条不是取消普通 timer wheel，而是取消 TIME_WAIT 自己集中管理的旧机制。精简状态与去集中竞争可能分别要求节省和增加内存。

## 5. 取舍

紧凑对象降低关闭后存量，但多一种对象形态增加转换、引用与查询分支。省空间不意味着能无成本保留无限短连接；端口与协议隔离也不能靠随意缩短等待时间解决。实际 `sizeof` 随架构配置变化，本篇未编译测量。

## 6. 用户态对照

lwIP 2.2.1 在 `tcp_tw_pcbs` 链上保留 PCB，由 `tcp_slowtmr()` 检查 2*MSL 后清理（`src/core/tcp.c:1440`），没有照搬 Linux 这套独立 tw 对象转换。[固定源码](https://github.com/lwip-tcpip/lwip/blob/77dcd25a72509eb83f72b033d219b1d40cd8eb95/src/core/tcp.c#L1440) 较小规模下可选更简单管理，但协议等待与存量问题仍在。

## 7. 验证

目标机运行已有短连接程序，用 `ss -tan state time-wait` 观察应用退出后对象仍存留，再查看相关 slab 统计。不要用本机的 slab 对象大小推断所有配置，也不要把“没有 fd”当成内核已无状态。实验未运行。

## 要点回顾

- 应用生命周期结束后，协议记忆仍有价值。
- minisock 缩减状态，未取消隔离和查找责任。
- 去共享竞争有时要用额外内存交换。

## 自测

1. TIME_WAIT 必须对应活着的应用 fd 吗？
2. tw 是否保留整个 tcp_sock？
3. 去掉集中 TIME_WAIT timer 是否意味着不用时间轮？

<details><summary>答案</summary>

1. 不必。2. 不保留，只转移必要状态。3. 不是，每对象仍使用普通 timer 子系统。

</details>

## 与 DPDK/VPP 的对照

把连接从活跃表迁到紧凑的结束状态表，可类比数据面对象分生命周期管理；但 TCP 的旧报文防护不是一般转发表老化。用户态省略等待状态是改变协议行为，不能只记为性能优化。
