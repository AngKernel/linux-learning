# L06 参考答案

本篇回答：怎样注册最小 hook 并解释命中矩阵？前置：[L06 题面](../../L06-netfilter/)。预计阅读 15 分钟。

文件：`lab_hook.c`、`Makefile`；先看矩阵，再看代码，再按题面构建/运行。本模块 API 已与 v6.18 核对，**未完成目标内核编译、加载或卸载实测**，不可当作已验证模块。

宿主先复制到树外：

```bash
mkdir -p /tmp/ll-l06-module
cp labs/solutions/L06-netfilter/lab_hook.c labs/solutions/L06-netfilter/Makefile /tmp/ll-l06-module/
```

再按题面的 `KERNEL_SRC`、`BUILD_DIR` 和 `MODULE_DIR` 构建。代码安全取头、拒绝分片，匹配目标 Echo request 后先累加，再决定 ACCEPT/DROP；不校验 ICMP checksum，所以计数不等于协议验证成功的包数。`NF_IP_PRI_FILTER` 见 `include/uapi/linux/netfilter_ipv4.h:39`；`init_net` 见 `include/net/net_namespace.h:204`。默认只作用于 VM 的初始 network namespace。

<details><summary>矩阵与思考题答案</summary>

仅考虑题面隔离 IPv4 路由路径、没有其他提前丢包：

| init_net 中的 hook | 外部→本机目的 | 本机→外部目的 | l6a→l6b 转发 |
|---|---|---|---|
| PRE_ROUTING=0 | 有 | 无 | 有 |
| LOCAL_IN=1 | 有 | 无 | 无 |
| FORWARD=2 | 无 | 无 | 有 |
| LOCAL_OUT=3 | 无 | 有 | 无 |
| POST_ROUTING=4 | 无 | 有 | 有 |

每列要按题面改正确 `dst`。Echo reply 不匹配本模块；开启 DROP 的提前 hook 会阻止后续阶段，因此不能用同一包同时验证整张表。

1. 路由结果、方向、namespace 与匹配条件改变了包是否通过该点。
2. 不经；目的在 l6b，初始 namespace 只转发。l6b 有自己的 LOCAL_IN，但该模块没在那里注册。
3. skb 数据可在 fragments 中；应使用安全 helper 而不是越界读取。
4. 不能。packet tap 与 netfilter 的位置不同；应同时查 hook 计数与应用行为。

</details>

要点回顾：在单一 namespace 中画路径；每轮单 hook；退出先注销；计数不是 checksum 验证。与 DPDK/VPP 对照：节点动作要结合图位置解释，skb 的非线性与 mbuf chain 有相似的访问限制，所有权规则仍不同。
