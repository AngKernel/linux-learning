# L07 参考答案

本篇回答：怎样构造可检查边界的计数程序、怎样解释性能表？前置：[L07 题面](../../L07-xdp/)。预计阅读 15 分钟。

文件 `drop_udp.bpf.c` 是原创示例，使用 BTF map 声明和一个 map lookup helper；不依赖 libbpf 头文件。先完成题面，再读代码与本参考。已经使用 clang 的 BPF target 编译；加载、verifier 和收发性能【未实跑】。

在宿主编译到树外（本环境 x86_64；其他架构须调整 asm UAPI 头路径），然后把两个对象拷贝到 guest `/tmp/l07/`，如用 `env/ssh.sh 1 'mkdir -p /tmp/l07; cat > /tmp/l07/count.o' < /tmp/ll-l07/count.o`：

```bash
KERNEL_SRC=/home/chen/code/linux-lab/src/linux-6.18
mkdir -p /tmp/ll-l07
clang -O2 -g -Wall -Wextra -Werror -target bpf \
  -I "$KERNEL_SRC/tools/include/uapi" -I /usr/include/x86_64-linux-gnu \
  -DLAB_DROP=0 -c labs/solutions/L07-xdp/drop_udp.bpf.c -o /tmp/ll-l07/count.o
clang -O2 -g -Wall -Wextra -Werror -target bpf \
  -I "$KERNEL_SRC/tools/include/uapi" -I /usr/include/x86_64-linux-gnu \
  -DLAB_DROP=1 -c labs/solutions/L07-xdp/drop_udp.bpf.c -o /tmp/ll-l07/drop.o
```

无 VLAN、未分片 IPv4 UDP/9000 匹配后，key 1 增加；DROP 版本再增加 key 2；key 0 统计全部程序执行。不做 UDP checksum 校验，也不承诺识别所有 tunnel/多缓冲帧；这是一条有明确边界的练习策略。每个 map key 的值是所有 CPU 累计之和，取测试前后差。加载时 verifier 的成功仍需单独验证，clang 成功不等于 verifier 接受。

<details><summary>四道思考题答案</summary>

1. 没有 ARP 或控制连接，待测数据流可能根本没建立，零接收会产生误导。
2. key 0 包含该接口的其他 IP、ARP 等包；仅 key 1 是匹配条件的执行次数。
3. 用发包端统计、VM1 XDP map 命中以及必要时对端链路抓包互相核对。
4. native 在驱动路径，generic 在 skb 路径；两者基线不同，不能合并为同一个结果。

</details>

空白记录表：

| 轮次/模式 | 实际发送 pps | map/规则命中差 | 接收 pps | guest CPU | QEMU CPU | 限制 |
|---|---|---|---|---|---|---|
| 基线/count/native-drop/generic-drop/INPUT-drop | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 |

若在低速下各模式 CPU 都很低，只能说负载不足以区分；若 guest 看似省 CPU 但宿主 QEMU 占满，也不能据此预测物理 NIC 表现。`drivers/net/virtio_net.c:6042` 处理挂载请求，`:1840` 有 DROP 分支，是路径依据而非性能证明。

要点回顾：正确匹配优先；per-CPU 值要累加；先后采样做差；记录实际 offered rate。与 DPDK/VPP 对照：类似 worker 私有计数与入口早丢，但仍受内核调度、virtio 和 verifier 约束。
