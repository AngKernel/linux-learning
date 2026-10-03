# L06：在 netfilter hook 计数与丢包

本篇回答：hook 位置怎样改变看见的流量？安全读取 skb 头与直接强转有什么区别？前置：[内核基础](../../notes/00-kernel-basics/)、[收发包路径](../../notes/02-datapath/rx-tx/)，完成 L03。预计阅读 15 分钟，操作 2–3 小时。

目标：写一个可卸载模块，只匹配指定目的地址的未分片 IPv4 ICMP Echo request，先计数，再可选 DROP。禁止用宿主 6.8 模块树编译给 guest 6.18 加载。完整参考与 hook 对照答案放 [solutions](../solutions/L06-netfilter/)。模块构建/加载【未实跑】。

## 前置条件与步骤

1. 先按 [env](../../env/README.md) 完成 6.18 内核和模块构建，保留 `.config`、`Module.symvers`。在 guest 确认 `uname -r`，在宿主确认 `git -C /home/chen/code/linux-lab/src/linux-6.18 describe --always --dirty --tags`。两者还须对应相同构建配置与本次内核镜像。
2. 自己在树外模块目录编写 C 文件与 Kbuild：参数为 `hook=0..4`、`dst=IPv4地址`、`drop=0/1`；以 `nf_register_net_hook` 注册到 `init_net`；安全读取 IPv4 与 ICMP 头，不假定整个 skb 都在线性区。模块 init 校验参数并检查注册错误，exit 先注销再报告原子计数。不要逐包 printk。
3. 在**宿主**编译自己的模块，以下模块目录与 BUILD_DIR 均须已准备：

   ```bash
   KERNEL_SRC=/home/chen/code/linux-lab/src/linux-6.18
   BUILD_DIR="$HOME/.cache/linux-learning/build-6.18"
   MODULE_DIR=/tmp/ll-l06-module
   make -C "$KERNEL_SRC" O="$BUILD_DIR" M="$MODULE_DIR" modules
   ```

   不使用 `/lib/modules/$(uname -r)/build`。用 `env/ssh.sh 1 'cat > /tmp/lab_hook.ko' < "$MODULE_DIR/lab_hook.ko"` 将模块复制到 guest，仓库不保存 `.ko` 或其他构建产物。
4. guest 上执行 `sudo insmod /tmp/lab_hook.ko hook=1 dst=192.0.2.11 drop=0`；从 VM2 `ping -c 5 192.0.2.11`；guest `sudo rmmod lab_hook`、`sudo dmesg | tail -n 20`。逐个 hook 重新加载、发同样流量、卸载，把命中计数填入表中。每轮重新开始计数。
5. 选择一个确实命中的 hook，以 `drop=1` 重复；观察 ping、tcpdump 与模块计数，再卸载。将匹配目的改为 `.12`，从 VM1 发 ping，分别验证五个 hook。只丢 ICMP request，不影响实验 SSH TCP。
6. 为独立验证 FORWARD，使用下方的 guest 内隔离拓扑。实验 VM 必须没有阻断该转发的现有规则；先看 `iptables -S`、`nft list ruleset`，不要清空规则。创建前确认名称未占用，任一步失败即停止并清理自己创建的对象。

   ```bash
   old_forward=$(sysctl -n net.ipv4.ip_forward)
   sudo ip netns add l6a
   sudo ip netns add l6b
   sudo ip link add l6ra type veth peer name l6a0
   sudo ip link add l6rb type veth peer name l6b0
   sudo ip link set l6a0 netns l6a
   sudo ip link set l6b0 netns l6b
   sudo ip addr add 10.200.1.1/24 dev l6ra
   sudo ip addr add 10.200.2.1/24 dev l6rb
   sudo ip link set l6ra up
   sudo ip link set l6rb up
   sudo ip -n l6a addr add 10.200.1.2/24 dev l6a0
   sudo ip -n l6b addr add 10.200.2.2/24 dev l6b0
   sudo ip -n l6a link set lo up
   sudo ip -n l6b link set lo up
   sudo ip -n l6a link set l6a0 up
   sudo ip -n l6b link set l6b0 up
   sudo ip -n l6a route add default via 10.200.1.1
   sudo ip -n l6b route add default via 10.200.2.1
   sudo sysctl -w net.ipv4.ip_forward=1
   sudo ip netns exec l6a ping -c 3 10.200.2.2
   sudo insmod /tmp/lab_hook.ko hook=2 dst=10.200.2.2 drop=1
   sudo ip netns exec l6a ping -c 3 10.200.2.2
   sudo rmmod lab_hook
   sudo dmesg | tail -n 20
   ```

   可用 `drop=0` 重复五个 hook，填写转发路径这一列；不能把 l6b 内的 LOCAL_IN 当作 init_net 的 LOCAL_IN。
7. 清理：卸载仍在加载的 `lab_hook`，`sudo ip netns del l6a`、`sudo ip netns del l6b`（对应 veth 会被删除），`sudo sysctl -w net.ipv4.ip_forward="$old_forward"`。以上仅在实验 guest 执行。

## 预期观察与验收

产出三种流量×五个 hook 的命中矩阵：对 VM1 本地接收、VM1 本地发出、VM1 转发；给出至少一例“AF_PACKET 看见帧但目的应用没收到”的证据。计数值取自自己的流量与匹配条件；drop=1 时有命中但没有应用回复是预期之一，未命中的 hook 不能证明模块坏了。

源码锚点（v6.18）：`include/uapi/linux/netfilter.h:43` 五个 hook 枚举，`include/linux/netfilter.h:98` 的 `nf_hook_ops`，`:199` 注册 API；`include/linux/skbuff.h:4298` 的 `skb_header_pointer`。实际调用处：`net/ipv4/ip_input.c:260`、`:573`，`net/ipv4/ip_forward.c:162`，`net/ipv4/ip_output.c:120`、`:422`。本实验按 hook 位置解释，不扩展为所有优先级/conntrack/NAT 的完整覆盖。

## 要点回顾

- hook、network namespace（网络命名空间）和匹配条件共同决定命中。
- 注册成功、计数非零、DROP 生效要分别验收。
- 模块必须与 guest 内核匹配，退出必须注销 hook。

## 思考题与分层提示

1. 相同模块换 hook 后为什么可能计数为零？
2. 转发包是否必经 init_net 的 LOCAL_IN？
3. 为什么不能把 `skb->data` 后面的任意字节都直接解引用？
4. DROP 后 tcpdump 仍看得到包，能否说明 DROP 失败？

<details><summary>提示一：画路线</summary>对本地目的、本地源、路由转发各画一条路线，再标明在哪个 namespace。</details>
<details><summary>提示二：读代码</summary>看每个 NF_HOOK 的调用位置与后续 continuation；安全取头 helper 可以处理非线性 skb。</details>

## 与 DPDK/VPP 的对照

hook 可类比特定 graph 节点上的策略处理，但并非每个包遍历所有 hook。skb 可能非线性，像 chained mbuf 一样不能假设连续；返回 DROP 后所有权交回内核，不自行释放两次。
