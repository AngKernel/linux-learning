# 03 内存：分配策略与对象寿命

本篇回答：page、slab、kmalloc 分别解决什么问题？软中断为何不能随意分配？谁决定 skb 何时释放？page_pool 缓存什么？
前置阅读：[01 执行上下文](01-execution-context.md)。预计阅读时间：15 分钟。
源码基准：Linux v6.18。

## 从 page 到网络对象

page（页）是内核管理物理内存的重要单位，`struct page` 是描述信息，不是页里装的数据，定义见 `include/linux/mm_types.h:78`。`PAGE_SIZE` 来自配置，见 `include/vdso/page.h:13`；不要把所有架构、所有页粒度都写死成 4 KiB。当前实验系统可以用 `getconf PAGESIZE` 查看基本页大小。

网络接收需要保存包数据，未必每个包都独占一个 page。page_pool 分配页的接口见 `net/core/page_pool.c:669`；小包、页片段、分片与多缓冲包的布局取决于具体路径。页地址、CPU 虚拟地址与设备 DMA 地址也不是同一种地址；page_pool 的 DMA 映射调用在 `net/core/page_pool.c:531`，需要通过 DMA API 建立设备可用的映射。

slab（对象缓存机制）把页组织成可复用的小对象。`kmalloc` 提供按大小申请内存的通用接口；专用 `kmem_cache` 则面向某种固定大小对象。不能认为每次 kmalloc 都直接向页分配器申请一个新页。

`__alloc_skb` 先取得 skb 元数据，再取得数据区：

```c
skb = kmem_cache_alloc_node(cache, gfp_mask & ~GFP_DMA, node);
/* 省略检查与优化分支 */
data = kmalloc_reserve(&size, gfp_mask, node, &pfmemalloc);
```

出处：`net/core/skbuff.c:660`、`net/core/skbuff.c:670`。同函数也有 NAPI 对象缓存优化路径，见 `net/core/skbuff.c:656`。这段展示“元数据对象”和“包数据存储”是两次不同的资源获取，不能套用一个连续的 mbuf 布局模型。

## GFP 不是性能等级，而是允许分配器做什么

GFP（内存分配行为标志）告诉分配器调用者能承受哪些操作。以下名称、定义与限制均来自 `include/linux/gfp_types.h:306`、`include/linux/gfp_types.h:377`。

| 标志 | 是否允许调用者直接回收内存 | 适用理解 | 必须处理的情况 |
|---|---|---|---|
| GFP_KERNEL | 允许，因此可能睡眠 | 普通可睡眠进程上下文 | 分配仍可能失败 |
| GFP_ATOMIC | 不允许直接回收，可使用更低水位的保留空间 | 常见于不能睡眠、且希望提高成功机会的路径 | 不是永不失败，也不是所有原子上下文均可用 |
| GFP_NOWAIT | 不允许直接回收 | 接受快速失败的非阻塞分配 | 比 GFP_ATOMIC 更不应依赖保留空间 |

“软中断里用 GFP_ATOMIC”的原因是 softirq 不能阻塞等待直接回收，不是“这个内存由原子指令分配”。网络分配实例 `net/core/skbuff.c:797` 选择了 `GFP_ATOMIC | __GFP_NOWARN`；控制路径设置接口别名则用 GFP_KERNEL，见 `net/core/dev.c:1520`。

v6.18 文档明确说当前分配实现不支持 NMI 及部分严格不可抢占场景，如 raw_spin_lock 临界区，见 `include/linux/gfp_types.h:316`。所以不要把上表变成“只要禁止睡眠，就一定能调用任意 GFP_ATOMIC 分配”的通则。读网络代码时应沿用该 API 的上下文约束和失败处理。

## 引用计数解决寿命，不解决所有并发

引用计数（reference count）表达“还有多少持有者需要对象继续存在”。`sk_buff.users` 的类型是 `refcount_t`，见 `include/linux/skbuff.h:1097`；新 skb 初始化为 1 的网络代码在 `net/core/skbuff.c:372`：

```c
refcount_set(&skb->users, 1);
```

获取额外 skb 引用和释放引用的实现分别见 `include/linux/skbuff.h:2011`、`include/linux/skbuff.h:1286`。不要随便把 `refcount_t` 替换成普通整数或只凭 `atomic_t` 的名字推断生命周期语义。

skb 元数据与共享包数据还有不同的引用关系；共享信息里的 `dataref` 在 `include/linux/skbuff.h:612`。因此“释放一个 skb 引用”不一定等于“包数据的最后一份引用消失”。本篇不展开 clone 的位域编码。

`kref` 在引用计数上封装了最后一次释放时的回调，结构与操作定义见 `include/linux/kref.h:20`、`include/linux/kref.h:62`。网络实例：

```c
kref_put(&rd->rd_kref, rpcrdma_rn_release);
```

出处：`net/sunrpc/xprtrdma/ib_client.c:97`；初始化和增加引用见同文件 `net/sunrpc/xprtrdma/ib_client.c:115`、`net/sunrpc/xprtrdma/ib_client.c:67`。其 release 回调只是通知完成，见 `net/sunrpc/xprtrdma/ib_client.c:73`，并非所有 release 回调都直接 kfree。最后一次引用退出时“做什么”，必须读取回调本身。

引用计数非零也不能保证两个 CPU 同时修改字段是安全的；对象寿命与字段一致性需要分别分析。反过来，拿到一个已失效的裸指针后再增引用，也救不了 use-after-free。

## page_pool：为接收缓存回收页

page_pool（页池）面向网络接收等场景，减少反复分配/释放与 DMA 映射的成本。它与 slab 的主要对象不同：一个偏向接收数据所用的页或网络内存，另一个偏向小对象分配。

真实驱动例子为 `drivers/net/ethernet/stmicro/stmmac/stmmac_main.c:2064`：

```c
rx_q->page_pool = page_pool_create(&pp_params);
```

从这里读参数，再跳到 `net/core/page_pool.c:650` 的分配路径及 `net/core/page_pool.c:832` 的回收条件。页是否仍被其他持有者引用，会影响能否直接回收；回收既可能走本地缓存，也可能走 ring。不同驱动不一定采用 page_pool，不能把所有 RX buffer 回收都叫 page_pool。

## 动手：区分页、对象与包数量

以下只读观察未在 v6.18 实验 VM 实跑，sudo 权限取决于系统设置。

```sh
getconf PAGESIZE
cat /proc/meminfo
sudo sh -c 'cat /proc/slabinfo' | rg 'skbuff|kmalloc'
```

在建立/关闭一批实验连接前后比较。slab 活跃对象数不等于线上包数：缓存对象、分配路径和共享数据都会打破一一对应。没有特定 skb cache 项也不能直接推断“未使用 skb”，先核对构建配置和具体分配路径。

## 要点回顾

- 页、对象缓存、包数据与 DMA 地址属于不同层次。
- GFP 标志约束分配器行为；GFP_ATOMIC 仍会失败。
- skb 元数据和共享数据不能混为同一个引用计数。
- kref 的最后释放行为由回调定义。
- page_pool 优化接收内存回收，不是所有网卡驱动的统一实现。

## 自测

1. GFP_ATOMIC 为什么不能理解为“保证分配成功”？
2. 一个 skb 的 users 降低，能直接判断包数据已释放吗？
3. kref 最后一次 put 一定直接 kfree 吗？
4. slabinfo 中 skbuff 数量等于流量包数吗？

<details><summary>答案</summary>

1. 它避免直接回收并允许使用部分保留空间，但内存仍可能不足，且上下文限制仍存在。
2. 不能，还要看是否最后一个元数据引用及共享数据引用。
3. 不一定，要读取 release 回调；本例通知 completion。
4. 不等于，分配缓存、引用和多种数据布局都会影响统计。

</details>

## 与 DPDK/VPP 的对照

mempool 与 slab/page_pool 都通过复用减少分配成本，但内核需要兼顾不同执行上下文、全系统内存压力和 DMA 生命周期。熟悉 mbuf refcnt 有助于理解持有关系，却不能把它直接映射为 skb 的所有引用计数；更不能假设内核接收缓存全部来自固定大小、预先准备好的同一种 pool。
