任务：编写 notes/00-kernel-basics/，这是面向"读懂网络子系统代码"的内核基础速成。原则：每个知识点只讲到读懂网络代码够用的程度，并且都要配一段 net/ 或 drivers/net/ 中的真实代码作为例子（文件路径:行号）。

篇目：
01 执行上下文：进程上下文、硬中断、软中断、tasklet、workqueue、内核线程。说明每种上下文能否睡眠、能否被抢占、哪些网络代码跑在哪种上下文里。附一张"上下文 × 允许的操作"对照表
02 系统调用如何进入内核：以 recv() 为例，从用户态陷入，经过系统调用表、文件描述符、VFS，一直到 socket 层的入口（只讲到这里，后面属于网络栈）
03 内存：页、slab 与 kmalloc、GFP 标志（为什么软中断里要用 GFP_ATOMIC）、引用计数（refcount_t、kref），简单介绍 page_pool
04 同步：spinlock 及 _bh/_irqsave 变体各自防的是谁、mutex、原子操作、per-CPU 变量、RCU（重点讲：读侧为什么几乎没有开销，写侧付出了什么）；内存屏障只讲概念
05 数据结构与编码惯用法：list_head、hlist、rbtree、container_of、ops 函数指针表（C 语言里的"面向对象"）、goto 式错误处理、likely/unlikely、__rcu 等注解、EXPORT_SYMBOL
06 读内核代码的方法：自顶向下读；第一遍跳过错误处理路径；ops 指针实际指向哪个函数怎么查（grep 赋值位置，再用 ftrace/bpftrace 在运行时确认）；用 compile_commands.json + clangd 做跳转；用 git log 和 git blame 查设计动机
07 DPDK ↔ 内核概念对照表：rte_mbuf 与 sk_buff、PMD 与内核驱动、rx_burst 轮询与 NAPI、lcore 与软中断所在的 CPU、rte_ring 与内核中的各类队列、mempool 与 slab/page_pool、RSS、EAL 初始化与驱动 probe 等。每一行写清相同点、不同点，以及为什么不同
08 调试与观测工具入门：printk/dmesg、/proc/net 与 /sys/class/net、ss、ethtool -S、ftrace、bpftrace、perf，每个工具给出 2–3 条网络相关、拿来就能用的命令
