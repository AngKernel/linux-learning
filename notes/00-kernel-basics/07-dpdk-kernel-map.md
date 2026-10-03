# 07 DPDK ↔ 内核概念对照

本篇回答：已有数据面经验可以迁移到哪里？哪些一一对应最容易误导？为什么内核需要不同设计？
前置阅读：[01](01-execution-context.md) 至 [05](05-data-structures-and-idioms.md)。预计阅读时间：12 分钟。
源码基准：Linux v6.18；DPDK/VPP 对照只讨论概念，不承诺跨版本结构布局相同。

## 先对功能，再对边界

下面的“为什么不同”是根据运行环境和已核对实现得到的工程解释，不冒充某个历史提交作者的原话。每行包含一段内核真实代码或关键表达式，可据此继续追踪。

| DPDK 概念 → 内核概念 | 相同点 | 不同点 | 为什么不同 | v6.18 网络代码锚点 |
|---|---|---|---|---|
| rte_mbuf → sk_buff | 都描述包数据、长度、元信息与持有关系 | skb 元数据、线性数据与分片可以分离，共享数据和元数据有不同引用 | 内核协议层需要 clone、排队、重组及多种来源的数据存储 | `refcount_set(&skb->users, 1)`，`net/core/skbuff.c:372`；元数据/数据分配 `:661`、`:670` |
| PMD → 内核网卡驱动 | 都管理设备、描述符和 DMA 收发 | 内核驱动接入 net_device、IRQ、NAPI 和系统生命周期；PMD 常由应用轮询 | 内核服务多个进程且与调度、设备管理共享机器资源 | `.ndo_start_xmit = e1000_xmit_frame`，`drivers/net/ethernet/intel/e1000/e1000_main.c:824` |
| rx_burst 轮询 → NAPI poll | 都批量收包以摊薄开销 | NAPI 的 poll 受 budget、完成与重调度协议约束，也可回收 TX；返回语义不是 mbuf 数组接口 | 需要在吞吐与其他内核工作之间安排执行机会 | `netif_napi_add(netdev, &adapter->napi, e1000_clean)`，`drivers/net/ethernet/intel/e1000/e1000_main.c:1009` |
| lcore → 执行网络工作的 CPU | 都关注亲和性、NUMA 和本地数据 | softirq 是执行上下文，不是一个由应用独占的常驻 lcore；threaded NAPI 另有线程 | CPU 还要处理系统调用、中断与调度任务 | `this_cpu_ptr(&softnet_data)`，`net/core/dev.c:7747`；线程创建 `:1636` |
| rte_ring → 内核中的队列 | 都用于保存待处理对象或跨执行流交接 | 内核可能使用链表、skb 队列、描述符环、树；生产者数与锁协议各异 | 队列承担的排序、丢弃、唤醒和内存记账职责不同 | `__skb_queue_tail(list, skb)`，`net/core/sock.c:515`；这里由外层持 IRQ 保存锁 |
| mempool → slab / page_pool | 都通过复用减少分配成本 | slab 偏小对象，page_pool 偏接收数据页与 DMA 回收；内核还受 GFP 与全局回收约束 | 不同上下文允许的阻塞行为、内存压力和对象生命周期不同 | `rx_q->page_pool = page_pool_create(&pp_params)`，`drivers/net/ethernet/stmicro/stmmac/stmmac_main.c:2064` |
| RSS → RSS + IRQ/软件处理映射 | 同类网卡都能按流 hash 选择 RX queue | RSS 队列选择不等于最终协议栈 CPU；IRQ 亲和性、RPS 等还影响后续执行 | 硬件分流与软件 CPU 调度是不同层的问题 | `IXGBE_WRITE_REG(hw, IXGBE_RETA(i >> 2), reta)`，`drivers/net/ethernet/intel/ixgbe/ixgbe_main.c:4273`；RPS backlog `net/core/dev.c:5261` |
| EAL 初始化 → 内核初始化 + bus/driver probe | 都准备运行环境和设备资源 | probe 是设备匹配后的生命周期回调，不是整个内核的 EAL；内存/调度早已存在 | 内核是长期运行的全系统资源管理者，支持模块与设备变化 | `.probe = e1000_probe`，`drivers/net/ethernet/intel/e1000/e1000_main.c:183` |

DPDK 侧依据其官方[mbuf 文档](https://doc.dpdk.org/guides/prog_guide/mbuf_lib.html)、[PMD 文档](https://doc.dpdk.org/guides/prog_guide/ethdev/ethdev.html)、[ring 文档](https://doc.dpdk.org/guides/prog_guide/ring_lib.html)、[mempool 文档](https://doc.dpdk.org/guides/prog_guide/mempool_lib.html) 和 [EAL 文档](https://doc.dpdk.org/guides/prog_guide/env_abstraction_layer.html)。访问时页面显示 DPDK 26.07.0；这里只借用稳定概念，Linux 代码锚点仍固定 v6.18。

## 三个容易误用的迁移

“每个 RX queue 一个 owner”的经验有助于理解设备轮询，但不能推出同一 socket 的所有状态只有该 owner 访问。应用可在另一 CPU 调用 recv；内核也可能用软件转向。因此先问对象属于 queue、CPU 还是 socket，再谈同步。

“ring 就是固定数组环”只描述一种容器。上表的接收队列实际是 `sk_buff_head`，类型见 `include/linux/skbuff.h:337`；网络入队代码在 `net/core/sock.c:488` 还做内存额度判断、所有者设置、加锁和唤醒。只看到入队一行，会漏掉这些协议。

“poll budget 等于这一轮拿到多少包”也过于简化。`net/core/dev.c:7580` 的 `__napi_poll` 按驱动回报的 work 处理本轮状态；具体 poll 还可能做发送完成清理。比较 DPDK burst 时应对齐实际工作和 API 契约，不能仅拿返回数字作包数横比。

## 动手：把硬件队列与 CPU 分开观察

以下只读命令未在 v6.18 实验 VM 实跑；先从 `ip -br link` 选实验网卡，修改 IFACE。驱动不支持某项时会报“不支持”，这也是能力差异的结果。

```sh
IFACE=eth0  # 改为实验 VM 的真实网卡名
ethtool -i "$IFACE"
ethtool -x "$IFACE"
cat /proc/interrupts
```

第一项找驱动，第二项读 RSS indirection table（重定向表），第三项观察 IRQ 到 CPU 的统计。不能仅凭 RSS 表宣布“流的所有处理都在这个 CPU”；还需结合 [08](08-observation-tools.md) 的 NAPI 观测。单队列虚拟网卡或回环接口不适合验证多队列硬件 RSS。

源码练习：把上表八个入口各找一次，尝试用一句话回答“这个对象谁创建、谁调用、谁回收”。一旦回答不出来，就先停止套类比，沿当前对象的生命周期读下去。

## 要点回顾

- 对照功能可以加速入门，对照结构布局容易误导。
- lcore、CPU、softirq、NAPI 是不同维度。
- 内核队列不统一等于 rte_ring。
- RSS 决定硬件分流，后续 CPU 还受其他机制影响。
- EAL 与 probe 不在同一职责层次。

## 自测

1. sk_buff 可以直接当成内核版 rte_mbuf 的相同内存布局吗？
2. RSS 表指向 queue 2，能推出所有 TCP 操作都在 CPU 2 吗？
3. 为什么把 probe 称为内核的 EAL 不准确？
4. sk_buff_head 入队路径为什么可能需要锁和唤醒？

<details><summary>答案</summary>

1. 不能，只能类比包描述符职责；数据布局和共享关系需单独读。
2. 不能。队列编号不是 CPU 编号，IRQ/RPS/系统调用还会改变执行位置。
3. probe 是设备生命周期中的一环，内核内存与调度基础设施在它之前已存在。
4. 队列可能被多个执行流访问，而且应用等待接收数据，需要配合状态和等待机制。

</details>

## 与 DPDK/VPP 的对照

VPP 的 packet vector（包向量）和 node graph（节点图）强调批处理与节点间传递；它适合帮助理解“分层处理”和局部批量，但内核调用链不会因此自动成为同样的 graph scheduler。VPP worker 与内核 CPU 的所有权假设也不同。VPP 侧参考实际访问的[多线程说明](https://docs.fd.io/vpp/25.10/developer/corearchitecture/multi_thread.html)和 [VLIB 说明](https://docs.fd.io/vpp/25.10/developer/corearchitecture/vlib.html)。
