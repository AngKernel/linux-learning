# F-Stack：保留 BSD 协议语义，替换它依赖的运行环境

本篇回答：搬运内核 TCP 需要替换哪些接口？DPDK mbuf 与 BSD mbuf 如何衔接？为什么用户态 socket 不意味着零拷贝或任意多线程安全？

前置阅读：`lwip.md`、DPDK mbuf 与 RSS。预计阅读时间：25 分钟，源码练习另需 45 分钟。

固定 commit：**`eb6b32c825543a29dafcc92288e20bfd7db6362b`**。本地 `/tmp/p6-sources/f-stack`；无前缀路径相对此目录。实际访问的[上游固定版本](https://github.com/F-Stack/f-stack/tree/eb6b32c825543a29dafcc92288e20bfd7db6362b)。Linux 对照为 `v6.18`。未使用不存在的 `v1.24` tag，结论全部按此 commit 核实。

注意此版本已包含 `thread_mode` 和可选零拷贝 API。项目 README 不同段落还出现不同 FreeBSD 历史版本描述，见 `README.md:12`、`README.md:24`；本篇不根据它猜测当前移植代码精确对应哪个 FreeBSD release，以 commit 为准。

## 1. 架构：把设备、时钟和系统调用外壳换掉

```mermaid
flowchart LR
  A[DPDK RX burst] --> B[ff_dpdk_process_packets]
  B --> C[ff_veth_input]
  C --> D[包装成 FreeBSD mbuf]
  D --> E[虚拟 Ethernet input]
  E --> F[FreeBSD IPv4 / TCP]
  F --> G[BSD socket receive buffer]
  G --> H[ff_recv / ff_read / event API]
  H --> I[应用缓冲区]
```

RX loop 和批处理入口见 `lib/ff_dpdk_if.c:3789`、`lib/ff_dpdk_if.c:2646`。`ff_veth_input()` 包装缓冲区，再调用虚拟接口输入，见 `lib/ff_dpdk_if.c:2224`、`lib/ff_veth.c:551`。BSD Ethernet/IP/TCP 处理入口分别在 `freebsd/net/if_ethersubr.c:796`、`freebsd/netinet/ip_input.c:456`、`freebsd/netinet/tcp_input.c:1490`。

Linux 的“设备 → IP/TCP → socket → 应用”层次仍可对应，但 F-Stack 运行的是所移植的 BSD 协议代码，不是对 Linux `tcp_v4_rcv()` 的包装。Linux 对照入口见 `Linux net/ipv4/tcp_ipv4.c:2202`。

## 2. 包缓冲区与复制：两个 mbuf 不是同一结构体

NIC/DPDK 使用 `rte_mbuf`；BSD 栈使用 `struct mbuf`。`ff_mbuf_gethdr()` 分配 BSD metadata，并用 `m_extadd()` 引用 DPDK 数据和自定义释放函数，见 `lib/ff_veth.c:467`、`lib/ff_veth.c:475`。多 segment 在 `lib/ff_dpdk_if.c:2258` 逐段包装。因此 RX 接入可以共享 payload，仍要维护两套描述和释放规则。

普通 socket receive 仍通过 `uiomove()` 交付到调用者内存，见 `freebsd/kern/uipc_socket.c:3031`，其 F-Stack 实现见 `lib/ff_kern_subr.c:163`。用户态内的复制不会因没有 syscall 自动消失。

此 commit 的可选 `ff_zc_recv()` 将 socket buffer 的 mbuf chain 交给调用者，见 `lib/ff_syscall_wrapper.c:1360`、`lib/ff_syscall_wrapper.c:1384`；`FF_ZC_RECV` 构建选项见 `lib/Makefile:240`，归还 API 约束见 `lib/ff_api.h:572`。不能把可选专用 API 的性质赋给普通 `ff_recv()`，也不能只看宏就宣称已验证零拷贝：本次只跟到了链交付实现，没有做 NIC/应用端到端实测。

与 Linux `sk_buff` 一样，BSD mbuf 的存在并不自动要求复制 payload；`Linux include/linux/skbuff.h:885` 可作为另一种 descriptor / fragment 设计的对照。

## 3. 查找：保留 BSD PCB hash，RSS 负责此前的分流

精确连接查找选择 hash bucket，再在 bucket 链中比较连接，见 `freebsd/netinet/in_pcb.c:2429`。IPv4 hash 将带 seed 的远端地址 Jenkins hash 与两个端口组合，见 `freebsd/netinet/in_pcb.h:511`、`freebsd/netinet/in_pcb.h:520`。完整匹配仍需要本地/远端地址和端口，不能把 hash 输入误写成完整的匹配条件。

RSS 配置启用后与硬件支持的类型取交集；可选 symmetric RSS key 也在 DPDK 接入层，见 `lib/ff_dpdk_if.c:1196`、`lib/ff_dpdk_if.c:1216`、`lib/ff_dpdk_if.c:1230`。RSS hash 与 BSD PCB hash 不是同一个用途：前者选 queue/执行位置，后者在栈内部找连接。

## 4. 定时器：协议 timer 经 callout 适配到 DPDK 时间

- RTO、delayed ACK 等 TCP timer kinds 映射到 handlers，见 `freebsd/netinet/tcp_timer.c:271`。`tcp_timer_activate()` 更新逻辑 timer，选最早到期者重置连接的 callout，见 `freebsd/netinet/tcp_timer.c:906`。不是“每一种逻辑 timer 永远对应一个独立 callout”。
- TIME_WAIT 路径保留状态并启动 `TT_2MSL`，见 `freebsd/netinet/tcp_timewait.c:147`、`freebsd/netinet/tcp_timewait.c:183`；本地连接特例在同函数中，不能说所有连接都等同一时长。
- 实际参与 F-Stack 构建的是 `ff_kern_timeout.c`，见 `lib/Makefile:292`。它按 tick 在 callwheel bucket 检查超时，见 `lib/ff_kern_timeout.c:338`，不能直接拿 FreeBSD 原始 kernel timer 实现当运行事实。
- 传统路径用 `rte_get_timer_hz()` 配置 DPDK 周期 timer，callback 调 `ff_hardclock()`，见 `lib/ff_dpdk_if.c:1538`、`lib/ff_dpdk_if.c:306`；后者推进 ticks 和 callout，见 `lib/ff_kern_timeout.c:1251`。此 commit 的 graceful reload 模式还有 TSC 自驱动分支，见 `lib/ff_dpdk_if.c:3660`。

## 5. 线程：不要拿旧的多进程结论覆盖此 commit

传统多进程路线使各进程持有自己的协议全局状态，再由 queue/RSS 分配流。此版本还明确支持 `thread_mode` 的单进程多线程初始化：配置将进程数折成 1，并保留 worker 数，见 `lib/ff_config.c:1601`；主循环初始化当前 stack thread，见 `lib/ff_dpdk_if.c:3617`，执行 loop 通过 EAL lcore launch，见 `lib/ff_dpdk_if.c:3998`。

worker 初始化还会分配独立 VNET（FreeBSD 网络虚拟化状态域）与 callwheel，见 `lib/ff_freebsd_init.c:175`、`lib/ff_freebsd_init.c:211`、`lib/ff_freebsd_init.c:213`。因此可以确认每线程栈实例的设计意图；**尚未完成此新模式下全部 PCB/VNET 全局状态、锁与共享资源的审计**。例如 `lib/ff_lock.c:62` 的 lock-class wrapper 是空实现，不能据此推导所有锁都不存在；也不能据 FreeBSD 源码中有锁断言就保证任意应用线程可共享连接。线程模型细化是本篇最优先的【未确认】项。

连接固定到核需要分流、应用调用线程和协议上下文一致；RSS 不会自动解决 app 跨线程调用。此版本是否在所有 active/passive open、reload 和 offload 组合下均保持该约束，没有实跑验证。

## 6. TCP 完整度：保留能力，不等于移植后全部验证过

| 能力 | 源码支持与限制 |
|---|---|
| CC | 构建纳入 NewReno、CUBIC，见 `lib/Makefile:547`、`lib/Makefile:549`；源码 fallback 默认名为 cubic，见 `freebsd/netinet/cc/cc.c:82`；实际启动配置未测 |
| SACK | 接收处理调用 `tcp_sack_doack()`，发送恢复使用 `tcp_sack_output()`；`freebsd/netinet/tcp_input.c:2547`、`freebsd/netinet/tcp_output.c:293` |
| Window scaling / timestamps | 有选项解析与输出逻辑；`freebsd/netinet/tcp_input.c:3530`、`freebsd/netinet/tcp_input.c:3538`、`freebsd/netinet/tcp_output.c:837`、`freebsd/netinet/tcp_output.c:843` |
| TSO | 配置与硬件 capability 共同决定启用，输出填写 DPDK TCP_SEG 与 tso_segsz；`lib/ff_dpdk_if.c:1310`、`lib/ff_dpdk_if.c:3386`；checksum offload 配置也有关，未实测 |
| LRO | 配置允许时检查硬件能力，否则可选软件 LRO；`lib/ff_dpdk_if.c:1255`；接收经过 `ff_lro_rx()` 及 BSD TCP LRO 实现入口，见 `lib/ff_dpdk_if.c:2270`、`lib/ff_veth.c:537` |

这里只列核实过的传统 TCP 路径，不把 bundled FreeBSD 目录中所有算法文件都算成“默认启用并已验证”。

## 7. API、简化与代价

`ff_socket()`、`ff_read()`、`ff_recv()` 提供 BSD 风格函数，并进入移植后的内核式调用链，见 `lib/ff_syscall_wrapper.c:917`、`lib/ff_syscall_wrapper.c:1190`、`lib/ff_syscall_wrapper.c:1502`。应用不必按 raw callback 或 future 重写整个 I/O 模型，但仍要适配 F-Stack 初始化和 loop；普通 Linux FD 与 F-Stack FD 的互操作范围没有在本次测试。

核心取舍是保留 TCP 状态机与 socket 语义，替换设备输入、时间驱动、调度和部分 OS 服务。推测这适合“愿意控制部署环境，但不愿重新验证一套全新的 TCP”的应用。代价是兼容层会成为正确性风险：timer 失配、buffer 释放和线程上下文出错，都可能破坏原协议代码依赖的不变量。拥有成熟协议源码不能免除移植后的验证。

## 8. 项目测试与动手观察

`tests/README.md:3` 明确测试目标是 `lib/` glue layer（适配层）：unit suite 通过 stub/wrap 隔离 DPDK，integration suite 启动真实 EAL 但使用 `--no-huge --no-pci`，见 `tests/README.md:7`、`tests/README.md:8`。测试存在不证明 TCP RFC 或真实 NIC TSO/LRO 的完整覆盖。

本次未编译、未实跑测试与硬件实验。可以先追踪两个数据生命周期，再设计实验：

```sh
cd /tmp/p6-sources/f-stack
git rev-parse HEAD
rg -n 'm_extadd|ff_mbuf_ext_free' lib/ff_veth.c
rg -n 'ff_zc_recv|kern_zc_recvit' lib/ff_syscall_wrapper.c
rg -n 'ff_hardclock|rte_timer_manage' lib/ff_dpdk_if.c lib/ff_kern_timeout.c
```

观察题：收到一个多 segment DPDK packet 后，哪个 descriptor 先释放、谁最终释放 payload？普通 recv 和专用 ZC recv 的答案有什么不同？答案应由实际构建配置和释放调用链给出。

## 要点回顾

- 搬运的是协议代码及其语义，设备、时间和 OS 服务仍需适配。
- DPDK mbuf 与 BSD mbuf 是两层 metadata，可共享 payload。
- 普通 recv 仍会复制，可选 ZC API 有不同所有权约定。
- TCP 逻辑 timer 经 callout 和 F-Stack 时间轮驱动。
- 此 commit 有 thread_mode，不能照搬只有多进程的旧描述。
- 最大风险是移植边界正确性，不能以 FreeBSD 历史成熟度替代验证。

## 自测

1. 两个 mbuf 结构同时存在，是否一定复制 payload？
2. 为什么要看 `lib/Makefile` 才能确定实际 timer 实现？
3. `thread_mode` 配置存在，能否证明所有 TCP 状态都正确分片？

<details>
<summary>参考答案</summary>

1. 不一定。BSD mbuf 可用 external storage 引用 DPDK 数据，仍需正确释放两层 metadata。
2. 仓库同时保留 FreeBSD 原始代码与适配实现，真正链接的是构建文件选中的实现。
3. 不能。需要继续审计全局变量、VNET、锁、入口线程和连接归属，本篇已将其列为未确认。

</details>

## 与 DPDK/VPP 的对照

DPDK 仍负责 queue、burst 和设备能力。相比 VPP 重新组织 TCP 与 session 的方式，F-Stack 更强调继承 BSD socket / PCB / timer 抽象；它提醒你，性能收益可以来自替换执行环境，不必首先重写拥塞控制。但这种路线会保留较多原内核内部结构与适配债务。
