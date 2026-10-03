# L08：AF_XDP 收包与 TUN 路径对照

本篇回答：包怎样从 XDP 进入用户态？UMEM 与四个 ring 的所有权如何流转？怎样比较两条入口的吞吐与时延？前置：[用户态协议栈](../../notes/04-userspace-stacks/)、[收发包路径](../../notes/02-datapath/rx-tx/)，完成 L05/L07。预计阅读 20 分钟，操作 2–3 小时。

目标：用上游 `xdp-bench` 的 `xsk-drop` 确认包进入 AF_XDP 用户态，再用 `xsk-tx` 测反射 RTT（往返时延）。与 L05 的 TUN 丢弃/ICMP 回复模式使用相同输入帧、相同负载做对照。这里不实现 TCP，不复制第三方源码；原创建流工具与答案放 [solutions](../solutions/L08-af-xdp/)。全部 AF_XDP/VM 测试【未实跑】。

## 前置条件

两台 guest；VM1 接收，VM2 发流。额外依赖为包含 `xsk-drop`/`xsk-tx` 子命令的 xdp-tools（不是同名老 xdpsock）、Python 3、ethtool、iproute2。`env/` 未保证预装这一版 xdp-tools；先查 `xdp-bench --version`、`xdp-bench xsk-drop --help`，须包含题面使用的 `-q/-C/-A/-d`。安装/编译入口是已访问的 [xdp-tools 上游](https://github.com/xdp-project/xdp-tools)，依赖与源码留仓库外；本次未安装。

工具模式与参数以实际访问的 [xdp-bench 上游手册](https://github.com/xdp-project/xdp-tools/blob/main/xdp-bench/README.org) 为依据。`xsk-drop` 在用户态收后丢弃，`xsk-tx` 经用户态交换 MAC 后原路发回；它不生成 ICMP Echo reply。命令行参数可能随工具版本变更，保存本机 help 与版本，不能把内核 v6.18 当成用户态工具版本。

## 操作步骤

1. **固定接口和队列。** 在 VM1 记录 `ip -details link show dev "$LAB_IF"`、`ethtool -l "$LAB_IF"`、`ethtool -k "$LAB_IF"`。确认无其他 XDP。若支持，保存原 Combined 数并 `sudo ethtool -L "$LAB_IF" combined 1`，读回确认。若无法单队列，必须用 RX queue 统计/steering 确认所选流到 queue 0；不能把另一队列的零收包解释为 AF_XDP 故障。不要假设所有 QEMU 组合支持相同功能。
2. **先验证 TUN 基线。** VM1 按 L05 运行 `/tmp/l05-echo --sink`，配置 `l5tun=10.77.0.1/24`，记录 `old_forward=$(sysctl -n net.ipv4.ip_forward)` 后开启 `sudo sysctl -w net.ipv4.ip_forward=1`。使用实验 guest 的干净转发表/过滤规则，不清空现有防火墙。VM2 待测 IP 帧目的为 `10.77.0.2`，Ethernet 目的 MAC 明确填 VM1 数据 NIC 的 MAC；无需给 `.2` 配真实地址。
3. **相同输入帧发流。** 在 VM2 记录自己的数据接口与两端 MAC。使用 solutions 中的单向发流工具，它仅构造 ICMP/Ethernet，不实现 TCP：

   ```bash
   # 把下面 MAC 换成 VM1 数据 NIC 的实际地址；不要使用管理 NIC。
   sudo python3 /work/labs/solutions/L08-af-xdp/icmp-load.py \
     --interface "$LAB_IF" --peer-mac 52:54:00:12:34:01 \
     --mode burst --count 20000 --pps 1000 --size 64
   ```

   VM1 结束 `--sink`，记录其 `received` 与发送端实际 pps。非持久 TUN 会随程序最后一个 fd 关闭而消失，每轮重新启动程序后都要重新配置 `.1/24` 和 link up，再发流。反复做 100、500、1000 pps；再逐步升高直至出现瓶颈，Python 发包器若先饱和，则该轮只能测到下界。其他参数保持一致。
4. **AF_XDP copy 收包。** 先关闭 TUN 程序。VM1 运行 `xdp-bench xsk-drop -q 0 -C copy -A native -d 30 "$LAB_IF"`，VM2 重复同样发流。**该工具接管所选队列的全部输入，可能让走数据 NIC 的 SSH 和 ARP 暂时不可用**；发流工具使用已知 MAC，管理使用 QEMU 控制台或独立管理口。只有数据 SSH 时，从 VM1 shell 预先启动这个有界后台轮次，再回 VM2 发包：

   ```bash
   # 先确认当前无 XDP；只在本实验新 guest 上执行。
   # 保存为 /tmp/l08-round.sh；脚本参数为已确认的 VM1 数据 NIC。
   cat > /tmp/l08-round.sh <<'SH'
   #!/usr/bin/env bash
   set -u
   nic=$1
   sleep 3
   timeout --signal=INT --kill-after=5 35 \
     xdp-bench xsk-drop -q 0 -C copy -A native -d 30 "$nic"
   result=$?
   ip link set dev "$nic" xdpdrv off
   exit "$result"
   SH
   sudo bash -c 'nohup bash /tmp/l08-round.sh "$1" </dev/null >/tmp/l08-xsk.log 2>&1 &' _ "$LAB_IF"
   ```

   等待三秒后开始发流。最长约 43 秒之后重连并读日志，检查退出状态与残留挂载。cleanup 只卸载本轮预先确认空闲接口上的 native XDP。日志为空、bind/加载失败均不是成功。若 native 不支持，改 `-A skb -C copy` 和 cleanup 的 `xdpgeneric off`，单列 generic 结果。
5. **zero-copy 协商。** 能力验收单独再试 `-A native -C zero-copy`，记录成功/errno 与工具输出。失败后继续 copy 模式，不把“AF_XDP 已创建”当成 zero-copy 已启用。virtio_net 有相关实现，但仍受 virtio 特性、UMEM headroom、队列和设备约束；禁止写“virtio 永远不支持”或“必然零拷贝”。不改内核代码来绕过检查。
6. **RTT 对照。** TUN 轮次改为 L05 默认 echo 模式，VM2 用上面工具 `--mode rtt --count 100 --pps 20 --size 64`。AF_XDP 轮次把工具改为 `xsk-tx`，其余参数保持相同，同样使用有界后台包装；VM2 再测 RTT。发流工具在同一 VM2 单调时钟里计时，分别识别反射的 Echo request 与真正的 Echo reply；输出成功/超时数、p50/p95/max。先用低速 tcpdump 验证方向与类型，再关闭抓包重复三轮。
7. **清理。** 确认后台测试结束且无残留 XDP；结束本次 TUN 进程；恢复 `net.ipv4.ip_forward="$old_forward"` 与原 Combined 数。不要删除系统原有的 XDP/路由；如果初始环境有这些对象，换独立 VM 后再做实验。

## 预期观察与验收

验收为 copy 模式用户态 RX 计数非零、输入流量与工具计数可解释、RTT 两模式成功且类型不同，以及 zero-copy 协商证据；并不要求 zero-copy 一定成功。输出如下空白表，每格都填实测或明确失败原因：

| 路径/模式 | 实际输入 pps | 用户态 RX pps/总数 | 丢失 | RTT p50/p95 | guest/host CPU | 条件 |
|---|---|---|---|---|---|---|
| TUN sink / echo | 待测 | 待测 | 待测 | 待测 | 待测 | 经 IP 路由 |
| AF_XDP copy drop / tx | 待测 | 待测 | 待测 | 待测 | 待测 | queue、native/skb |
| AF_XDP zero-copy（若成功） | 待测 | 待测 | 待测 | 待测 | 待测 | 协商证据 |

TUN echo 包含 IP 路由和 ICMP 修改，xsk-tx 是 L2 反射；两者是**入口方案整体路径**对照，不能据此隔离 socket API 的单独开销。RTT 包含 VM2 调度、virtio/TAP/宿主和 VM1 工作，不是单向入口时延。吞吐用实际发送率与接收率，同时报告瓶颈与失败，不能把发包器上限当成 AF_XDP 上限。

源码定位：`Documentation/networking/af_xdp.rst:42` 的 FILL/COMPLETION 方向，`:53` 的 queue bind，`:220` 的 XSKMAP，`:243` 的 copy/zero-copy；`include/uapi/linux/if_xdp.h:17`、`:18` 的强制 bind flags，`:107` 的 zero-copy 查询标志；`drivers/net/virtio_net.c:5921` 的 pool enable、`:5932` 的 headroom 检查。此处源码注释有旧 samples 路径，不要求仓库中不存在的 xdpsock 示例。

## 要点回顾

- 设备与 queue ID 必须匹配 XSKMAP 的目标。
- AF_XDP 与 zero-copy 不是同一个承诺。
- 四个 ring 通过转移 buffer 所有权配合。
- 相同输入与可解释的出口行为是比较前提。
- 用同一端时钟测 RTT，不伪造跨 VM 单向时延。

## 思考题与分层提示

1. FILL ring 没有 buffer，XSKMAP 配对正确能否继续收包？
2. RX 描述符消费后，其 buffer 什么时候可以再次交给内核？
3. copy 模式为什么仍能称为 AF_XDP？
4. 这次 TUN 与 xsk-tx 的 RTT 差能否全部归因于一次内存复制？

<details><summary>提示一：所有权</summary>给 UMEM frame 标注“用户可写”“内核可用”，再画 RX、FILL、TX、COMPLETION 的生产者和消费者。</details>
<details><summary>提示二：实验设计</summary>检查队列、输入速率、报文是否真到达用户态，拆分整条往返路径，注意每种模式实际做了哪些工作。</details>

## 与 DPDK/VPP 的对照

UMEM 与固定 frame pool 类似 mbuf pool，ring 类似用户/设备间交接队列；AF_XDP 仍依赖内核驱动、XDP 重定向和受约束的队列绑定。它不是把 PMD 直接搬到用户进程，也不提供 TCP 连接能力。
