# B2 连接查找的无锁读：允许对象迅速复用，再验证它是谁

源码基准：Linux 6.18，`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`。函数、字段与调用关系已用 `rg` 核对；演进来自本地 `git log -S`、`git blame` 和完整提交正文。以下以 IPv4 TCP established hash（ehash）为主；它也承载一些并非 ESTABLISHED 状态的对象，不能把表名直接当作状态限制。

## 1. 问题：每个包查一次连接，读锁也会变成写流量

包到达后，要把地址和端口映射到具体连接。与此同时，别的 CPU 会创建、关闭、删除连接，甚至把刚释放的内存拿去创建另一个连接。

用读写锁保护哈希表看起来很自然：包多、创建关闭少，读者并发读。但获得/释放读锁仍需更新锁的共享状态；多个 CPU 因此争夺同一条缓存线。2008 年引入 RCU 的提交明确把去掉这种共享缓存线写入列为动机。

更困难的问题是内存回收：查到一个裸指针以后，读者尚未取得引用，写者就可能删掉并释放它。仅有“哈希表读操作没上锁”不构成一个安全方案。Linux 把它拆成三件事：**RCU 保护遍历期间可访问的内存，引用计数固定对象生命周期，身份复查确认这个对象仍符合本次查询。**

## 2. 约束：高包率之外，还要承受连接高周转

- 长连接要求逐包查找便宜；短连接要求分配、释放也便宜。把所有对象都留到 RCU 宽限期以后再回收，可能增加短连接场景的存量内存与回收工作。
- 查找与删除不能依赖某个应用线程及时运行；包可能在任何接收 CPU 到达。
- IPv4 四元组不足以代表所有隔离条件。网络命名空间、绑定设备等也参与匹配，不能因优化而把包交给其他租户。
- 同一 ehash 要容纳完整 socket、TIME_WAIT 对象、请求对象。它们共享查找字段的布局，但体积和析构方式不同。
- 查到对象后仍需执行 TCP 状态机。查找表无锁不等于整个 TCP 接收路径无锁，也不保证对象其他字段同时保持不变。

## 3. 方案：RCU、type-safe slab、引用、二次匹配、nulls

RCU 的基本分工是：读者声明自己正在读共享对象；写者按发布/摘链规则更新可见结构，再把需要延迟的释放推到旧读者都退出之后。这个等待区间称为宽限期。它不要求读者取得同一把读锁，但必须准确选择延迟回收的对象；本例普通 TCP socket 延迟的是 slab 页，单个 socket 仍可先释放复用。

### 先分清四种不同的保证

| 机制 | 保证什么 | 不保证什么 |
| --- | --- | --- |
| RCU 读侧临界区与 RCU 链表访问 | 参与相应回收协议的内存可被安全遍历 | 不自动锁住整个对象，也不自动固定逻辑连接身份 |
| `SLAB_TYPESAFE_BY_RCU` | slab 页的释放等待宽限期，旧地址仍处于该类型缓存的存储范围 | **不延迟单个对象释放或再次分配** |
| `refcount_inc_not_zero()` 成功 | 取得当时这个活对象的一份引用，不能把零引用对象复活 | 不证明该地址仍是第一次匹配到的连接；不是通用 acquire 屏障 |
| 取引用后重新 `inet_match()` | 排除“第一次匹配后，该地址已变成另一个不匹配对象”的情况 | 不替代随后的 socket 状态同步 |

第二行不是对实现的猜测。[include/linux/slab.h:102](../../../src/linux-6.18/include/linux/slab.h#L102) 的警告明确区分 slab 页与对象；还明确要求对象身份检查放在获取引用之后。引用计数 API 的内存顺序说明见 [include/linux/refcount.h:321](../../../src/linux-6.18/include/linux/refcount.h#L321)。

TCP 确实使用这个 slab 标志：IPv4 的 `tcp_prot.slab_flags` 在 [net/ipv4/tcp_ipv4.c:3527](../../../src/linux-6.18/net/ipv4/tcp_ipv4.c#L3527)，IPv6 对应项在 [net/ipv6/tcp_ipv6.c:2380](../../../src/linux-6.18/net/ipv6/tcp_ipv6.c#L2380)。`proto_register()` 将标志带到完整 socket、request 和 TIME_WAIT 的缓存创建中，见 [net/core/sock.c:4061](../../../src/linux-6.18/net/core/sock.c#L4061)、[net/core/sock.c:4097](../../../src/linux-6.18/net/core/sock.c#L4097)、[net/core/sock.c:4122](../../../src/linux-6.18/net/core/sock.c#L4122)。

### 数据结构：共享的是定位字段，不是完整对象大小

| 字段/结构 | 用途 | 位置 |
| --- | --- | --- |
| `inet_hashinfo.ehash/ehash_mask` | 桶数组与桶索引掩码 | [include/net/inet_hashtables.h:147](../../../src/linux-6.18/include/net/inet_hashtables.h#L147) |
| `inet_hashinfo.ehash_locks/ehash_locks_mask` | 写者使用的锁数组；锁索引与桶索引各有掩码 | 同上 |
| `inet_ehash_bucket.chain` | `hlist_nulls_head`，链尾携带桶编号 | [include/net/inet_hashtables.h:39](../../../src/linux-6.18/include/net/inet_hashtables.h#L39) |
| `sock_common.skc_hash/skc_addrpair/skc_portpair` | 快速过滤与地址、端口匹配 | [include/net/sock.h:150](../../../src/linux-6.18/include/net/sock.h#L150) |
| `sock_common.skc_net/skc_bound_dev_if` | 网络命名空间与设备绑定隔离 | [include/net/sock.h:177](../../../src/linux-6.18/include/net/sock.h#L177) |
| `sk_nulls_node/sk_refcnt` | 在 `sock` 中映射到公共头的链接节点与引用计数 | [include/net/sock.h:359](../../../src/linux-6.18/include/net/sock.h#L359) |

`request_sock` 和 `inet_timewait_sock` 也以 `sock_common` 开头，见 [include/net/request_sock.h:50](../../../src/linux-6.18/include/net/request_sock.h#L50)、[include/net/inet_timewait_sock.h:33](../../../src/linux-6.18/include/net/inet_timewait_sock.h#L33)。因此同一查找能先读公共身份字段；失败后释放引用则由 `sock_gen_put()` 按类型走不同析构，见 [net/ipv4/inet_hashtables.c:506](../../../src/linux-6.18/net/ipv4/inet_hashtables.c#L506)。不能因为返回类型写着 `struct sock *` 就无条件访问完整 `sock` 的尾部字段。

### 查找的实际顺序

正常 IPv4 本地投递由 `ip_local_deliver_finish()` 开启 RCU 读侧临界区，`ip_protocol_deliver_rcu()` 分发 TCP 处理。[net/ipv4/ip_input.c:187](../../../src/linux-6.18/net/ipv4/ip_input.c#L187)、[net/ipv4/ip_input.c:227](../../../src/linux-6.18/net/ipv4/ip_input.c#L227)

`tcp_v4_rcv()` 调用 `__inet_lookup_skb()`；后者可能沿用 skb 已关联的 socket，否则进入 `__inet_lookup()`，先查 ehash，再考虑 listener。调用点与分支见 [net/ipv4/tcp_ipv4.c:2246](../../../src/linux-6.18/net/ipv4/tcp_ipv4.c#L2246)、[include/net/inet_hashtables.h:472](../../../src/linux-6.18/include/net/inet_hashtables.h#L472)、[include/net/inet_hashtables.h:395](../../../src/linux-6.18/include/net/inet_hashtables.h#L395)。因此并非每个包都一定执行同样完整的一轮哈希查找。

`__inet_lookup_established()` 本身不在入口调用 `rcu_read_lock()`，不能据此判断它“没有 RCU”；读侧保护由调用环境提供。其核心代码如下：

```c
begin:
sk_nulls_for_each_rcu(sk, node, &head->chain) {
        if (sk->sk_hash != hash)
                continue;
        if (likely(inet_match(net, sk, acookie, ports, dif, sdif))) {
                if (unlikely(!refcount_inc_not_zero(&sk->sk_refcnt)))
                        goto out;
                if (unlikely(!inet_match(net, sk, acookie, ports, dif, sdif))) {
                        sock_gen_put(sk);
                        goto begin;
                }
                goto found;
        }
}
if (get_nulls_value(node) != slot)
        goto begin;
```

见 [net/ipv4/inet_hashtables.c:527](../../../src/linux-6.18/net/ipv4/inet_hashtables.c#L527)。第一轮 `sk_hash` 和 `inet_match()` 筛掉无关对象，减少不必要的引用计数原子操作；成功取得引用后，第二次匹配处理复用竞态。

`inet_match()` 检查网络命名空间、端口对、地址对及绑定设备关系，见 [include/net/inet_hashtables.h:343](../../../src/linux-6.18/include/net/inet_hashtables.h#L343)。它不是只比较哈希值。两个连接即使哈希碰撞，也不会仅因此被视为相同连接。

注意具体失败分支：**6.18 在引用取得失败时返回未找到；二次身份匹配失败时释放引用并重启。** 不能把 RCU 文档中示意性的“任何失败都重试”抄成当前 TCP 实现。

### 为什么第一次匹配不够：一个地址可以先后装两个连接

| 时间 | CPU R：读者 | CPU W：创建/关闭连接 |
| --- | --- | --- |
| T0 | 从桶中读到地址 P，看到连接 A 符合查询 | |
| T1 | 尚未取得引用 | 把 A 摘链，最后一份引用消失，单对象归还 slab |
| T2 | 仍处于 RCU 临界区 | 同一缓存把 P 分配给连接 B，初始化并发布 |
| T3 | 对 P 的非零引用计数加一，得到的可能是 B 的引用 | |
| T4 | 第二次 `inet_match()` 不符合，释放 B 的引用并从桶头重查 | |

RCU 与 type-safe slab 使 T3 不会仅因 slab 页已归还其他用途而访问野内存；第二次身份检查使它不会把 B 当 A。二者解决的问题不同。若新对象的键也相同，查询需要的是当前匹配该键的活对象，而不是证明它与第一次读到的分配实例相同。

因此也不能先拿这个裸指针里的普通自旋锁，再假定地址被固定：每次分配可能重新初始化锁。slab 注释对这种用法给出了专门限制；TCP 的缓存创建没有通过构造器把这种锁变成跨复用不变的对象。[include/linux/slab.h:149](../../../src/linux-6.18/include/linux/slab.h#L149)、[net/core/sock.c:4135](../../../src/linux-6.18/net/core/sock.c#L4135)

初始化与可见顺序是另一个必须满足的条件，不能由“引用计数”四个字代替。当前 `sock_init_data_uid()` 在发布初始 `sk_refcnt` 前有 `smp_wmb()`，并指向 RCU 文档说明。[net/core/sock.c:3696](../../../src/linux-6.18/net/core/sock.c#L3696) 本文核对的是现有查找协议，不把这段代码当作可以脱离其发布、遍历规则复制的通用模板。

### 为什么链尾不能只是 NULL：遍历可能走进另一条链

假设读者从桶 3 出发，途中某节点被删除、复用并插到桶 7。读者随后读取该节点的 `next` 时，可能沿着桶 7 继续走。若尾部都只是 NULL，它无法知道自己没有完整扫完桶 3，可能错误地报告“没找到”。

`hlist_nulls` 在链尾编码桶编号。读者扫到尾部时，检查 `get_nulls_value(node) == slot`；如果读到了 7，却期望 3，就从桶 3 重新开始。文档把它与“在传统遍历中增加读屏障”的方案对照，说明 nulls 如何避免额外的遍历屏障。[Documentation/RCU/rculist_nulls.rst:140](../../../src/linux-6.18/Documentation/RCU/rculist_nulls.rst#L140)

迭代宏还用编译器 `barrier()`，确保重启会重新读取桶头。它与 CPU 内存屏障不是同一件事。[include/linux/rculist_nulls.h:155](../../../src/linux-6.18/include/linux/rculist_nulls.h#L155)

二次身份匹配处理“命中的对象变了”，链尾标记处理“没有命中，却可能走错链”。缺少后者，即使每个命中都重新验证，也不能保证失败查询正确。

### 写端与 listener：仍然需要明确的生命周期协议

`inet_ehash_insert()` 用 `inet_ehash_lockp()` 选择自旋锁，持锁插入/替换节点；`inet_unhash()` 的非监听分支也持相应锁删除。[net/ipv4/inet_hashtables.c:705](../../../src/linux-6.18/net/ipv4/inet_hashtables.c#L705)、[net/ipv4/inet_hashtables.c:837](../../../src/linux-6.18/net/ipv4/inet_hashtables.c#L837) 所以“无锁读”没有消除写者间互斥，也没有消除命中对象的引用计数写入。

listener 使用另一种选择：插入监听表时设置 `SOCK_RCU_FREE`，析构时通过 `call_rcu()` 延迟**对象本身**的释放。监听 lookup 可以在 RCU 保护下省掉每次命中的引用计数修改。当前 `__inet_lookup()` 用 `refcounted` 区分两种返回结果，见 [net/ipv4/inet_hashtables.c:801](../../../src/linux-6.18/net/ipv4/inet_hashtables.c#L801)、[net/core/sock.c:2389](../../../src/linux-6.18/net/core/sock.c#L2389)、[include/net/inet_hashtables.h:405](../../../src/linux-6.18/include/net/inet_hashtables.h#L405)。若返回对象需要跨出相应保护区继续使用，调用者仍须满足自己的引用规则。

这不是矛盾：listener 往往活得久且被所有新连接共享；逐 SYN 原子加减的代价高。短连接完整 socket 数量大、周转快，立即复用单对象的价值更高。前者选对象级延迟回收，后者常用 type-safe slab 加引用和身份校验。

另一个版本边界：**Linux 6.18 的 UDP 没有沿用 TCP 的这个 slab 标志。** [net/ipv4/udp.c:561](../../../src/linux-6.18/net/ipv4/udp.c#L561) 明确注释无需因 `SLAB_TYPESAFE_BY_RCU` 而操作引用计数。不能用 2008 年提交提到的 UDP 前身机制来描述今天的 UDP。

## 4. 演进：把逐包共享写入移出查找快路径

数据全部出自提交正文，并非本文复测。

| commit / 作者 | 一句话动机 | 正文性能数据或定量说明 |
| --- | --- | --- |
| `3ab5aee7fe840b5b1b35a8d1ac11c3de5281e611` / Eric Dumazet，2008 | 把 TCP/DCCP established 与 TIME_WAIT 查找改成 RCU + `hlist_nulls` + 当时名为 `SLAB_DESTROY_BY_RCU` 的缓存，去掉读锁共享缓存线写入并避免每次释放 `call_rcu()`。 | 声称短连接不会因该回收策略变慢；**未提供数值基准**。当时尚未转换 bind/listen 表。 |
| `9db66bdcc83749affe61c61eb8ff3cf08f42afec` / Eric Dumazet，2008 | 网络查找已改成 RCU，ehash 写端可以从 rwlock 改为 spinlock。 | 正文解释当时实现的加解锁原子操作由两次减为一次；未提供吞吐/延迟实测。这个计数是历史实现说明，不推广到所有现今架构。 |
| `05dbc7b59481ca891bbcfe6799a562d48159fbf7` / Eric Dumazet，2013 | 合并 established 与 TIME_WAIT 的两条桶链，统一身份字段，为 SYN_RECV 进入主 ehash 作准备。 | 524,288 个桶的表，从 **8,388,608 B 降到 4,194,304 B**；不是完整 socket 存量内存减半。 |
| `3b24d854cb35383c30642116e5992fd619bdc9bc` / Eric Dumazet，2016 | listener 改为对象级 RCU 延迟释放，SYN flood 时避免逐包争用 `sk_refcnt`。 | 同一测试机 SYN flood 处理峰值从 **2.4 Mpps 到 3.2 Mpps，约 +33%**；正文还指出发送内存计数仍是后续争用点。 |
| `75d855a5e93e6f3d9b37a8719d69a5318f051453` / Eric Dumazet，2016 | 清掉 UDP 已不再需要的 `SLAB_DESTROY_BY_RCU` 分配标志，标明 TCP/UDP 在此处的演进分叉。 | 未提供性能数据；正文说明行为调整已由前序提交完成，本提交清理分配模式。 |
| `5f0d5a3ae7cff0d7fa943c199c3a2e44f23e1fac` / Paul E. McKenney，2017 | 重命名为 `SLAB_TYPESAFE_BY_RCU`，防止开发者误以为整个读侧临界区内单个对象不会被复用。 | 记录了这种误解导致的实际排错经历；未提供性能数据。属于语义澄清，并非新增整套机制。 |

复现取证：

```bash
git log -S 'SLAB_DESTROY_BY_RCU' -- net/ipv4/tcp_ipv4.c
git log -S 'get_nulls_value(node) != slot' -- net/ipv4/inet_hashtables.c
git log -S 'rwlock_t' -- include/net/inet_hashtables.h
git blame -L 545,566 -- net/ipv4/inet_hashtables.c
git log -S 'SOCK_RCU_FREE' -- net/ipv4/inet_hashtables.c
git show 3ab5aee7fe840b5b1b35a8d1ac11c3de5281e611
git show 3b24d854cb35383c30642116e5992fd619bdc9bc
```

## 5. 取舍：读者便宜了，正确性协议更复杂了

收益是逐包查找不必修改桶锁，短连接对象也能迅速归还并再次使用；长寿命 listener 则进一步省掉收包查询中的引用计数修改。查找字段前置且共用布局，让小对象与完整 socket 可以共用定位逻辑。

代价有三层。首先是实现约束：字段布局、发布顺序、引用、二次匹配、链尾标记、析构分派需要共同成立。其次是剩余硬件成本：完整 socket 命中仍修改 `sk_refcnt`，实际 TCP 处理还可能竞争 B1 的锁。最后是重试和哈希链长度：大量并发创建/关闭或很长的冲突链会提高查找工作量，RCU 不会把它们变成常数成本。

内存立即复用还会增加调试难度。旧地址可能已经是另一个完全合法的 TCP 对象；调试器看到“这里仍像一个 sock”并不能证明它还是原连接。对安全审查而言，检查“读指针时在 RCU 内”还不够，必须继续追踪取引用、身份复查以及退出保护区后的使用。

单核、连接归属固定、查找与删除不并发的场景无需支付完整的共享表协议。相反，如果允许任意线程操作连接，又只去掉引用或二次检查，就把性能改动变成生命周期漏洞。

## 6. 对照：Seastar 把并发问题变成 shard 归属问题

实际核对了 Seastar 官方源码 `e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b`：`tcp` 的 `_tcbs` 是 `std::unordered_map<connid, lw_shared_ptr<tcb>, connid_hash>`；`received()` 用连接键查表，再保留控制块指针。对应本地下载副本已用 `rg` 查证字段与调用位置。[官方固定版本 `tcp.hh`](https://raw.githubusercontent.com/scylladb/seastar/e417c0c0ebeb1f0578b1dd5b3dd4f65decff0a4b/include/seastar/net/tcp.hh)

结合官方教程的每核 share-nothing 模型，可以作出有限推论：在所属 shard 的同步查表片段内，没有另一个 CPU 同时删掉本地表项，就不需要 Linux 这套“共享链遍历途中对象复用”的 nulls 重启协议。异步任务跨出当前片段仍需要生命周期管理；不能据此说用户态栈不需要引用或没有回收问题。[官方教程](https://raw.githubusercontent.com/scylladb/seastar/master/doc/tutorial.md)

代价转移到连接归属、跨 shard 消息和负载分配。若一个连接的工作量超过其所属核能力，或者应用一定要跨核共享同一连接，就必须重新引入协调。对 Linux 来说，RCU 是在保留通用并发接口的前提下优化共享；对这类用户态模型来说，先减少共享才能进一步省掉这部分协议。

## 7. 验证：分别观察表查找、对象争用和连接周转

本轮没有运行内核压测。可以在相同 RX 分布和 CPU 亲和性下，分别测试稳定长连接、多 CPU 访问少量连接、大量短连接三种负载。

```bash
sudo perf record -a -g -- sleep 15
sudo perf report
```

观察 `__inet_lookup_established()`、收包处理及连接创建/析构的 CPU 样本。长连接吞吐提升而单核已经满载，与共享缓存线争用下降是两个不同解释；应同时记录包率、连接率、每核利用率和吞吐。如果平台支持 `perf c2c`，可进一步查共享缓存线，但需要符号与结构布局才能把热点地址归到引用计数或锁。

仅在函数入口加 kprobe，不能得出 nulls 重试次数或二次匹配失败次数：它们是**同一次调用内部**的 `goto begin`。此处没有核对到专门统计这两个重试分支的稳定计数器，因此不提供一个声称能直接统计它们的现成 bpftrace 脚本。要精确测量，需在匹配版本、可映射到具体指令的实验内核上布置内部探点；这不属于本次只读理解任务。

listener 的历史优化也不能通过一个 sysctl 关闭来做严格 A/B；重现 2016 年收益需要对应补丁前后的内核。当前源码与历史提交证明设计方向，不等于已经测得你这台机器上的收益。
