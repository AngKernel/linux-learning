# 内核基础速成：为读懂网络代码准备

本组回答：网络代码在哪里运行、如何进入、怎样管理内存和并发，以及如何用源码和实验验证判断。
前置阅读：C/C++、网卡队列及 DPDK/VPP 数据面经验；不要求内核阅读经验。预计阅读时间：约 2 小时，实验另计。

源码基准为 Linux **v6.18**，目录 `/home/chen/code/linux-lab/src/linux-6.18`。开工和收尾均执行 `git describe --always --dirty --tags`，结果为 v6.18；内核源码只读。文内引用均使用该版本的相对路径与行号。

## 文件与建议阅读顺序

| 顺序 | 文件 | 主要问题 |
|---|---|---|
| 1 | [01-execution-context.md](01-execution-context.md) | process/IRQ/softirq/tasklet/workqueue/thread 与允许的操作 |
| 2 | [02-syscall-to-socket.md](02-syscall-to-socket.md) | x86-64 recvfrom、fd、VFS 与 socket 分派的边界 |
| 3 | [03-memory-and-lifetime.md](03-memory-and-lifetime.md) | page、slab、GFP、引用计数、page_pool |
| 4 | [04-synchronization.md](04-synchronization.md) | spinlock 变体、mutex、atomic、per-CPU、RCU |
| 5 | [05-data-structures-and-idioms.md](05-data-structures-and-idioms.md) | list/hlist/rbtree、container_of、ops、清理和注解 |
| 6 | [06-reading-kernel-code.md](06-reading-kernel-code.md) | 跟踪主路径、解析函数指针、clangd、git 历史 |
| 7 | [07-dpdk-kernel-map.md](07-dpdk-kernel-map.md) | 八组概念的相同点、不同点和原因 |
| 8 | [08-observation-tools.md](08-observation-tools.md) | 日志、proc/sysfs、ss、ethtool、ftrace、bpftrace、perf |

每篇包含真实网络代码入口、动手步骤、要点、自测折叠答案以及 DPDK/VPP 对照。首次按表顺序读；遇到上下文、分配和锁问题，回查 01/03/04；实际跟踪前读 08。其余文件是 [REPORT.md](REPORT.md)（交付和验证记录）与 [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md)（后续实验选项）。

## 已完成与边界

八篇均已完成，不包含用户态 TCP 协议栈实现，也未提交第三方源码。Linux 函数、字段、配置和事件名均在本地 v6.18 查找后引用。glibc、DPDK、VPP、clangd、bpftrace 的外部链接仅使用本次实际访问成功的页面。

运行时实验**尚未在 v6.18 实验 VM 验证**：本次宿主是 6.8；没有安装 bpftrace，也没有匹配的 v6.18 构建数据库。Shell 代码块做了 bash 语法检查，工具参数做了帮助或官方文档核对，这不能替代运行验证。ftrace 使用独立 instance；compile_commands 需要已有构建产物。

01/04 的默认上下文和自旋锁规则以非 PREEMPT_RT 为前提，已说明 RT 差异但不展开 RT 专章。系统调用篇限定原生 x86-64 ABI；page_pool 用实际采用它的 stmmac 驱动举例，不推广到 virtio_net。DPDK/VPP 表为概念对照，不是结构 ABI 兼容承诺。
