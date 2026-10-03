# B2. RCU 查连接：地址还在，不代表还是那个连接

本篇回答：为什么查表不拿读锁？如何避免对象复用后认错连接？前置阅读：B1、RCU 与引用计数基础。预计阅读：10 分钟。源码基准：Linux v6.18。

## 1. 问题

每个 TCP 包都要找连接。读锁也会写共享锁变量，大量 CPU 查同一表就产生 cache line 争用。另一方面，短连接频繁创建、删除，不能让回收拖住吞吐。

## 2. 约束

查找同时发生删除、迁移和重新分配；相同地址可能已经是另一个 socket。地址端口之外还必须匹配 network namespace（网络命名空间）与设备绑定。ehash 名字里的 established 不表示它只装 ESTABLISHED 状态。

## 3. 方案

`__inet_lookup_established()` 用 RCU（读复制更新）遍历 `hlist_nulls`，见 `net/ipv4/inet_hashtables.c:527`。普通 TCP slab 标志是 `SLAB_TYPESAFE_BY_RCU`，见 `net/ipv4/tcp_ipv4.c:3527`。它延迟 slab 页回收，不延迟其中每个对象的复用；说明见 `Documentation/RCU/rculist_nulls.rst:124`。

核心顺序是：

```text
匹配 hash/连接身份 → refcount_inc_not_zero → 再匹配身份 → 返回引用
                                     失败则放引用并重试
链尾的 nulls 桶编号不匹配 → 重新查找
```

具体分支见 `net/ipv4/inet_hashtables.c:549`。首次匹配后，对象可能释放并被重用；拿到非零引用只证明当时有一个活对象，第二次匹配才验证它仍符合请求。`inet_match()` 同时检查 net、地址端口及绑定设备，见 `include/net/inet_hashtables.h:343`。链尾标记用于发现遍历转入其他桶，不是普通 NULL。

这个算法需要 RCU 临界区、正确发布/复用和引用协议共同成立。它不允许调用者拿到裸指针后无限期在读侧区外使用；也不意味着写端无需桶锁。listener 的对象级 RCU 生命周期另有设计，不能和普通连接 slab 安全混同。

## 4. 演进

| commit / 作者 | 动机 | 性能数据 |
|---|---|---|
| `3ab5aee7fe84` / Eric Dumazet | TCP/DCCP established 与 TIME_WAIT 表改用 RCU、nulls 链和当时名为 `SLAB_DESTROY_BY_RCU` 的缓存，避免查找写读锁缓存线。 | 该提交未提供性能数据；正文称避免逐次 `call_rcu` 对短连接的拖累。 |
| `5f0d5a3ae7cf` / Paul E. McKenney | 更名 `SLAB_TYPESAFE_BY_RCU`，纠正开发者误以为对象在读侧区内不会复用的理解。 | 该提交未提供性能数据。 |

`git blame -L 545,558 -- net/ipv4/inet_hashtables.c` 可看到重试骨架及后续 refcount、匹配实现调整。更名是语义澄清，不是 2017 年才开始允许对象复用。

## 5. 取舍

读侧少共享写入，换来二次验证、内存序与回收协议的复杂度。短连接、多核收益动机明确；专用单线程栈若照搬全套 RCU，可能只增加证明与维护成本。这是架构推断，不是当前机器测量。

## 6. 用户态对照

对 B1 所述 lwIP 单核心执行模型，连接对象的查找与修改可以在核心上下文内串行化，因而不必处理 Linux 相同的任意线程/softirq 并发回收问题。若用户态栈改为共享多核连接表，相同地址复用、持引用与身份验证问题仍然存在；“用户态”本身不是同步保证。

## 7. 验证

先逐行阅读上述 527–570 行并画出“匹配后对象被重用”的交错。运行期可比较受控短连接负载与长连接负载的系统级 `perf`；仅看到无读锁不能证明 RCU 生命周期正确。此处没有执行并发压力验证。

## 要点回顾

- RCU 安全要说清保护的是页、对象还是引用。
- 取得引用后仍需复查连接身份。
- 查表隔离不只靠四元组。

## 自测

1. slab 类型安全保证对象不变吗？
2. 为什么 refcount 成功后还检查身份？
3. nulls 标记与普通 NULL 有什么区别？

<details><summary>答案</summary>

1. 不保证对象不变，只限制页回收。2. 地址可能已变成另一个活 socket。3. 它还编码桶编号，支持发现链迁移并重试。

</details>

## 与 DPDK/VPP 的对照

单 worker 独占连接表时可用更直接的生命周期管理；跨 worker 共享表则仍需同步。不要把“poll mode”当作 RCU 的替代品：轮询决定怎么收包，所有权决定谁能并发改表。对照是基于 B1 执行模型的推论。
