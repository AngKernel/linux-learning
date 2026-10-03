# L05：TUN 与手工 ICMP 回复

本篇回答：读 TUN 和写 TUN 分别把包送向哪里？怎样让用户态响应 ping？前置：[内核基础](../../notes/00-kernel-basics/)、[收发包路径](../../notes/02-datapath/rx-tx/)，完成 L03。预计阅读 10 分钟，操作 90–120 分钟。

目标：写一个只支持无 IP options、未分片 IPv4 ICMP Echo 的小程序，理解 TUN（L3 虚拟网络设备）的方向。程序不是 TCP 栈；完整参考放 [solutions](../solutions/L05-tun/)。VM 路径【未实跑】。

## 前置条件与操作步骤

在 VM1 操作，需要 `/dev/net/tun`、root、C 编译器。使用新建的 `l5tun`，不改实验 NIC。

1. 程序打开 `/dev/net/tun`，用 `TUNSETIFF` 配置 `IFF_TUN | IFF_NO_PI`，设备名固定为 `l5tun`。启动后保持 fd 打开。自查每个系统调用返回值。
2. 另一终端配置（先确认没有同名设备）：

   ```bash
   sudo ip addr add 10.77.0.1/24 dev l5tun
   sudo ip link set l5tun up
   ip route get 10.77.0.2
   sudo tcpdump -ni l5tun -vv icmp
   ```

3. 程序循环 read，打印 IP 版本、总长度和协议。先不回复，在第三终端执行 `ping -c 3 -s 17 10.77.0.2`。保留观察；不要将 `.2` 配为任何内核接口地址。
4. 增加回复：仅处理目标 `.2` 的合法 Echo request；校验 IPv4/ICMP 长度、checksum 与分片标志；填写响应后通过同一 fd write 回内核。重试 `ping -c 3 -s 17 10.77.0.2`，再试 `-s 18`。记录偶数/奇数 payload 的处理结果。
5. 测试 `ping -c 1 -s 2000 10.77.0.2`，说明你的程序对分片的限制，不能悄悄把它算为实现失败或实现成功。结束程序，非持久 TUN 应随最后一个 fd 关闭而消失；用 `ip link show l5tun` 核实。

## 预期观察与验收

能够 read 到 IP 包，开头没有 Ethernet 头；回复功能加入后小 ping 可收到响应。目标是至少三次 id/seq/payload 一致的响应与错误输入边界说明。分片不是本实验的扩展目标，IPv6、IP options 不要求支持。预期现象不是本次运行记录。

源码起点：`include/uapi/linux/if_tun.h:34` 的 `TUNSETIFF`，`:72` 的 `IFF_NO_PI`；`drivers/net/tun.c:1985` 写入回调，`:1999` 转 `tun_get_user`；`:2033` 的 `tun_put_user`，`:2194` 读取回调。ICMP 类型见 `include/uapi/linux/icmp.h:26`、`:30`。

## 要点回顾

- TUN 传 IP 包，TAP 才对应 Ethernet 帧。
- fd 方向与内核设备收发方向需要分别记录。
- checksum、长度、分片是最小 ICMP 程序也不能忽略的边界。

## 思考题与分层提示

1. 从用户态 read 返回的包，对内核来说是什么方向？
2. 为什么不把 `10.77.0.2` 配给 TUN 接口？
3. 为什么 payload 取 17 和 18 两个长度？
4. 与直接从 virtio RX queue 收包相比，这条路径多了什么？

<details><summary>提示一：方向</summary>分别画“内核路由到 l5tun”和“用户 write 到 fd”两个箭头。</details>
<details><summary>提示二：排查顺序</summary>先看路由，再看 read 是否发生，再检查地址/长度/校验和；最后确认 write 后的内核接收路径。</details>

## 与 DPDK/VPP 的对照

TUN 类似把一个 L3 软件接口交给用户态处理，但内核仍负责前面的路由和后面的协议接收。它不是 PMD，也没有把真实网卡 RX descriptor 的所有权交给程序。
