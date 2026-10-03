# 05 数据结构与编码惯用法

本篇回答：侵入式链表怎么还原对象？ops 怎样选择实现？goto、注解与导出宏该怎样读？
前置阅读：[03 内存](03-memory-and-lifetime.md)、[04 同步](04-synchronization.md)。预计阅读时间：15 分钟。
源码基准：Linux v6.18。

## 不拥有对象的数据结构节点

侵入式（intrusive）结构把链接节点嵌入业务对象。链表节点本身不会替你分配业务对象，也不会自动负责寿命。

| 结构 | 先看什么 | 网络代码实例 | 适用理解 |
|---|---|---|---|
| list_head | 头节点、嵌入成员、遍历宏 | `net/ipv4/tcp_cong.c:22`、`net/ipv4/tcp_cong.c:29` | 双向循环链表；这里维护拥塞控制算法集合 |
| hlist | hash 选桶，再沿桶内链查找 | `net/core/dev.c:308`、`net/core/dev.c:314` | 桶头比普通双向链表头更小；它自身不是 hash 函数 |
| rbtree | 比较键、插入位置、平衡操作 | `net/ipv4/tcp_input.c:5132`、`net/ipv4/tcp_input.c:5168` | 红黑树；这里管理 TCP 乱序段 |

链表例子：

```c
list_for_each_entry_rcu(e, &tcp_cong_list, list) {
    if (strcmp(e->name, name) == 0)
        return e;
}
```

出处：`net/ipv4/tcp_cong.c:29`。`list` 是对象内嵌节点的成员名；宏恢复业务对象给 e。后缀 `_rcu` 提示还要检查调用者的读侧保护，它不会自动为所有调用者建立读侧临界区。

hlist 例子先由 `dev_name_hash` 选桶，再比较字符串，见 `net/core/dev.c:311`。rbtree 则先找位置，再挂节点并调整颜色：

```c
rb_link_node(&skb->rbnode, NULL, p);
rb_insert_color(&skb->rbnode, &tp->out_of_order_queue);
```

出处：`net/ipv4/tcp_input.c:5168`。这里只是“树为空”的分支，NULL parent 不能复制到一般插入代码。TCP 序号有回绕语义，读完整比较条件后才谈排序，不把无符号大小关系直接套进去。

## container_of：从成员地址恢复外层

```c
struct e1000_adapter *adapter =
    container_of(work, struct e1000_adapter, reset_task);
```

出处：`drivers/net/ethernet/intel/e1000/e1000_main.c:3507`。worker 收到的是嵌入的 work_struct 地址；减去成员在对象中的偏移，就能恢复 adapter。宏定义见 `include/linux/container_of.h:19`。它不分配对象，不查注册表，也不验证对象仍然活着；前提是指针确实指向指定类型的那个成员。

## ops：C 中可替换的行为集合

ops（操作表）是一组函数指针，常见于设备、文件和协议层。IPv4 stream socket 表的接收成员：

```c
.recvmsg = inet_recvmsg,
```

出处：`net/ipv4/af_inet.c:1071`。socket 创建时从匹配的协议类型项取得 ops，见同文件 `net/ipv4/af_inet.c:320`；上层在 `net/socket.c:1078` 读取 `sock->ops->recvmsg` 分派。

类似 C++ 虚函数的地方是“同一个调用点可以选择不同实现”。不成立的地方是：C 不自动提供继承、构造/析构或寿命保障，布局、注册、引用与同步全部显式编写。也要区别 `proto_ops` 与更下层的其他操作表，不见到 recvmsg 就把所有表混为一个。

## goto：资源获取的逆序清理

```c
data = kmalloc_reserve(&size, gfp_mask, node, &pfmemalloc);
if (unlikely(!data))
    goto nodata;
/* 省略成功路径 */
nodata:
kmem_cache_free(cache, skb);
return NULL;
```

出处：`net/core/skbuff.c:670`、`net/core/skbuff.c:699`。元数据已经分配，数据区却失败了，因此清理已拥有的元数据。读每个 label 时列出“进入这里时已经获取了哪些资源”，比把 goto 一律视为坏风格更有用。

较新的源码还会用作用域自动清理宏。`net/socket.c:2284` 的 `CLASS(fd, f)` 是例子；它意味着 fd 释放不一定再显示成所有出口上的手写 goto。两种方式都要跟踪资源所有权。

## 让编译器和工具参与检查

| 写法 | 它表达什么 | 网络代码例子 | 不能据此推断什么 |
|---|---|---|---|
| likely / unlikely | 分支倾向提示，某些配置也支持分析 | `net/core/skbuff.c:661` | 不改变真假语义，不保证 CPU 永远预测正确 |
| __rcu | 给类型检查/分析工具的 RCU 指针注解 | 对应 `net/core/dev.c:1554` 的 RCU 读取；字段定义 `include/linux/netdevice.h:2166` | 注解自身不会加锁或延迟释放 |
| __user | 提示用户地址空间指针 | `net/socket.c:2269` | 不能因此直接在内核解引用用户地址 |
| EXPORT_SYMBOL | 允许其他模块解析该内核符号 | `net/core/skbuff.c:703` | 不是导出给用户态的 libc 函数，也不保证稳定模块 ABI |

`likely/unlikely` 的宏定义见 `include/linux/compiler.h:76`；`__rcu` 的配置相关定义见 `include/linux/compiler_types.h:34`。读注解时把它当作“这里有契约要查”的提示，不当作运行时同步机制。

## 动手：自己还原一次分派

下面是只读源码练习，命令目标已核对。

```sh
cd /home/chen/code/linux-lab/src/linux-6.18
rg -n 'tcp_cong_list|list_for_each_entry_rcu' net/ipv4/tcp_cong.c
rg -n 'inet_stream_ops|recvmsg.*inet_recvmsg|sock->ops =' net/ipv4/af_inet.c
rg -n 'goto nodata|^nodata:|kmem_cache_free' net/core/skbuff.c
```

记录拥塞算法对象的嵌入节点、socket ops 的赋值来源、skb 分配失败时的资源清理。每个例子都能回答“对象在哪里、谁持有它、哪层在调用”。

## 要点回顾

- 链表、hash 桶、树节点不自动拥有业务对象。
- container_of 依赖正确类型、成员与有效寿命。
- ops 是行为分派，不自动带来 C++ 的对象管理。
- goto 清理路径按资源获取顺序检查。
- 注解、分支提示和符号导出不能替代同步及安全访问协议。

## 自测

1. hlist_for_each_entry 前为什么还要找 hash 桶？
2. container_of 能把任意地址变成有效对象吗？
3. 数据区分配失败时，为什么还需释放 skb 元数据？
4. EXPORT_SYMBOL 能让用户程序直接调用内核函数吗？

<details><summary>答案</summary>

1. hlist 提供桶内链结构，本身不计算业务键的 hash。
2. 不能，必须是有效对象中指定成员的地址。
3. 因为元数据先前已经分配，失败路径仍承担其释放责任。
4. 不能，导出针对内核模块符号解析，不是系统调用 ABI。

</details>

## 与 DPDK/VPP 的对照

DPDK 驱动的操作表有助于理解内核 ops；VPP 的 node 分派有助于接受“调用目标由注册关系决定”。但内核链表、树和 ops 涉及更多运行时创建、模块卸载及并发寿命。先恢复注册与所有权，再使用用户态框架经验类比。
