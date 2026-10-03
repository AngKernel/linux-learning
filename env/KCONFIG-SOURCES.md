# 调试配置的 v6.18 核对表

本篇回答：片段里的配置名是否存在、从哪里查看依赖？前置阅读：`README.md` 的编译部分。预计阅读时间：5 分钟（表格按需查阅）。

基准：源码 `git describe` = `v6.18`，路径 `/home/chen/code/linux-lab/src/linux-6.18`。以下逐项来自本次实际搜索；用途注释在 `kconfig/net-debug.config`。**符号存在不保证 olddefconfig 后启用**，构建脚本会再次检查实际 `.config`。本次因缺 pahole 没有完成 Kconfig 生成与全编译。未发现需虚构替代名称的配置项。

基础片段来自 `kernel/configs/kvm_guest.config:1`；它包含跨架构项，x86_64 不会启用 `CONFIG_S390_GUEST`，这不影响本调试片段的严格校验。

| 配置符号 | 定义位置 |
|---|---|
| `CONFIG_DEBUG_KERNEL` | `lib/Kconfig.debug:211` |
| `CONFIG_DEBUG_INFO_DWARF5` | `lib/Kconfig.debug:283` |
| `CONFIG_DEBUG_INFO_NONE` | `lib/Kconfig.debug:253` |
| `CONFIG_DEBUG_INFO_REDUCED` | `lib/Kconfig.debug:305` |
| `CONFIG_DEBUG_INFO_SPLIT` | `lib/Kconfig.debug:357` |
| `CONFIG_DEBUG_INFO_BTF` | `lib/Kconfig.debug:377` |
| `CONFIG_GDB_SCRIPTS` | `lib/Kconfig.debug:429` |
| `CONFIG_KALLSYMS` | `init/Kconfig:1935` |
| `CONFIG_KALLSYMS_ALL` | `init/Kconfig:1956` |
| `CONFIG_KPROBES` | `arch/Kconfig:117` |
| `CONFIG_KPROBE_EVENTS` | `kernel/trace/Kconfig:739` |
| `CONFIG_FTRACE` | `kernel/trace/Kconfig:194` |
| `CONFIG_FUNCTION_TRACER` | `kernel/trace/Kconfig:225` |
| `CONFIG_FUNCTION_GRAPH_TRACER` | `kernel/trace/Kconfig:244` |
| `CONFIG_DYNAMIC_FTRACE` | `kernel/trace/Kconfig:291` |
| `CONFIG_BPF_SYSCALL` | `kernel/bpf/Kconfig:27` |
| `CONFIG_BPF_JIT` | `kernel/bpf/Kconfig:42` |
| `CONFIG_BPF_EVENTS` | `kernel/trace/Kconfig:810` |
| `CONFIG_PERF_EVENTS` | `init/Kconfig:2020` |
| `CONFIG_NET_DROP_MONITOR` | `net/Kconfig:402` |
| `CONFIG_DEBUG_FS` | `lib/Kconfig.debug:662` |
| `CONFIG_IKCONFIG` | `init/Kconfig:745` |
| `CONFIG_IKCONFIG_PROC` | `init/Kconfig:757` |
| `CONFIG_SCHEDSTATS` | `lib/Kconfig.debug:1331` |
| `CONFIG_UNWINDER_FRAME_POINTER` | `arch/arm/Kconfig.debug:57`、`arch/x86/Kconfig.debug:249` |
| `CONFIG_UNWINDER_ORC` | `arch/x86/Kconfig.debug:233`、`arch/loongarch/Kconfig.debug:29` |
| `CONFIG_MODULES` | `kernel/module/Kconfig:2` |
| `CONFIG_MODULE_UNLOAD` | `kernel/module/Kconfig:132` |
| `CONFIG_VIRTIO_PCI` | `drivers/virtio/Kconfig:50` |
| `CONFIG_VIRTIO_MMIO` | `drivers/virtio/Kconfig:153` |
| `CONFIG_VIRTIO_NET` | `drivers/net/Kconfig:448` |
| `CONFIG_VIRTIO_BLK` | `drivers/block/Kconfig:307` |
| `CONFIG_VIRTIO_CONSOLE` | `drivers/char/Kconfig:96` |
| `CONFIG_FUSE_FS` | `fs/fuse/Kconfig:2` |
| `CONFIG_VIRTIO_FS` | `fs/fuse/Kconfig:32` |
| `CONFIG_NET_9P` | `net/9p/Kconfig:6` |
| `CONFIG_NET_9P_VIRTIO` | `net/9p/Kconfig:28` |
| `CONFIG_9P_FS` | `fs/9p/Kconfig:2` |
| `CONFIG_EXT4_FS` | `fs/ext4/Kconfig:2` |
| `CONFIG_DEVTMPFS` | `drivers/base/Kconfig:31` |
| `CONFIG_DEVTMPFS_MOUNT` | `drivers/base/Kconfig:50` |
| `CONFIG_PROC_FS` | `fs/proc/Kconfig:2` |
| `CONFIG_SYSFS` | `fs/sysfs/Kconfig:2` |
| `CONFIG_TMPFS` | `fs/Kconfig:166` |
| `CONFIG_TMPFS_POSIX_ACL` | `fs/Kconfig:180` |
| `CONFIG_TMPFS_XATTR` | `fs/Kconfig:198` |
| `CONFIG_OVERLAY_FS` | `fs/overlayfs/Kconfig:2` |
| `CONFIG_UNIX98_PTYS` | `drivers/tty/Kconfig:94` |
| `CONFIG_FHANDLE` | `init/Kconfig:1672` |
| `CONFIG_CGROUPS` | `init/Kconfig:997` |
| `CONFIG_NAMESPACES` | `init/Kconfig:1345` |
| `CONFIG_PACKET` | `net/packet/Kconfig:6` |
| `CONFIG_UNIX` | `net/unix/Kconfig:6` |
| `CONFIG_INET` | `net/Kconfig:114` |
| `CONFIG_IPV6` | `net/ipv6/Kconfig:7` |
| `CONFIG_NET_SCHED` | `net/sched/Kconfig:6` |
| `CONFIG_NET_SCH_FQ` | `net/sched/Kconfig:299` |
| `CONFIG_NET_SCH_NETEM` | `net/sched/Kconfig:195` |
| `CONFIG_BRIDGE` | `net/bridge/Kconfig:6` |
| `CONFIG_TUN` | `drivers/net/Kconfig:396` |
| `CONFIG_VETH` | `drivers/net/Kconfig:440` |
| `CONFIG_XDP_SOCKETS` | `net/xdp/Kconfig:2` |
| `CONFIG_NET_CLS_BPF` | `net/sched/Kconfig:562` |
| `CONFIG_NET_CLS_ACT` | `net/sched/Kconfig:702` |
| `CONFIG_NET_ACT_BPF` | `net/sched/Kconfig:841` |
| `CONFIG_TCP_CONG_ADVANCED` | `net/ipv4/Kconfig:469` |
| `CONFIG_TCP_CONG_CUBIC` | `net/ipv4/Kconfig:496`、`net/ipv4/Kconfig:725` |
| `CONFIG_TCP_CONG_BBR` | `net/ipv4/Kconfig:667` |
| `CONFIG_DEFAULT_CUBIC` | `net/ipv4/Kconfig:692` |
| `CONFIG_NETFILTER` | `net/Kconfig:165` |
| `CONFIG_NETFILTER_ADVANCED` | `net/Kconfig:220` |
| `CONFIG_NF_CONNTRACK` | `net/netfilter/Kconfig:82` |
| `CONFIG_NF_NAT` | `net/netfilter/Kconfig:418` |
| `CONFIG_NF_TABLES` | `net/netfilter/Kconfig:466` |
| `CONFIG_NF_TABLES_INET` | `net/netfilter/Kconfig:483` |
| `CONFIG_NFT_CT` | `net/netfilter/Kconfig:502` |
| `CONFIG_NFT_NAT` | `net/netfilter/Kconfig:561` |
| `CONFIG_NFT_MASQ` | `net/netfilter/Kconfig:543` |
| `CONFIG_NFT_REJECT` | `net/netfilter/Kconfig:589` |
| `CONFIG_NFT_COMPAT` | `net/netfilter/Kconfig:603` |
| `CONFIG_NETFILTER_XTABLES` | `net/netfilter/Kconfig:743` |
| `CONFIG_NETFILTER_XT_MATCH_COMMENT` | `net/netfilter/Kconfig:1211` |
| `CONFIG_NETFILTER_XT_MATCH_CONNTRACK` | `net/netfilter/Kconfig:1264` |
| `CONFIG_NETFILTER_XT_TARGET_LOG` | `net/netfilter/Kconfig:968` |
| `CONFIG_NETFILTER_XT_TARGET_MASQUERADE` | `net/netfilter/Kconfig:1057` |
| `CONFIG_IP_NF_IPTABLES` | `net/ipv4/netfilter/Kconfig:130` |
| `CONFIG_IP_NF_FILTER` | `net/ipv4/netfilter/Kconfig:184` |
| `CONFIG_IP_NF_NAT` | `net/ipv4/netfilter/Kconfig:221` |
| `CONFIG_IP_NF_MANGLE` | `net/ipv4/netfilter/Kconfig:265` |
| `CONFIG_IP_NF_RAW` | `net/ipv4/netfilter/Kconfig:301` |
| `CONFIG_NETFILTER_XTABLES_LEGACY` | `net/netfilter/Kconfig:761` |
| `CONFIG_IP_NF_IPTABLES_LEGACY` | `net/ipv4/netfilter/Kconfig:14` |
| `CONFIG_NET_NS` | `init/Kconfig:1402` |
| `CONFIG_INET_DIAG` | `net/ipv4/Kconfig:424` |
| `CONFIG_INET_TCP_DIAG` | `net/ipv4/Kconfig:436` |
| `CONFIG_INET_UDP_DIAG` | `net/ipv4/Kconfig:440` |
| `CONFIG_XDP_SOCKETS_DIAG` | `net/xdp/Kconfig:10` |

`DEBUG_INFO` 本身是被 DWARF choice 选择的隐藏符号（`lib/Kconfig.debug:227`）；`TRACING` 被相应 tracer 选择（`kernel/trace/Kconfig:169`），`BPF` 被 `BPF_SYSCALL` 选择（`kernel/bpf/Kconfig:27`）。未盲目设置不能直接选择的隐藏总开关。

## 要点回顾

- 每项都存在于 v6.18，但仍需检查最终 `.config`。
- BTF 依赖完整 DWARF、BPF 和适当版本的 pahole。
- 6.18 legacy iptables 的依赖不能用老版本配置印象代替。

## 自测题

1. 为什么设置 `CONFIG_DEBUG_INFO=y` 还不够？
2. 为什么 `NET_DROP_MONITOR=y` 不是 kfree_skb tracepoint 的唯一开关？
3. 为什么把 AF_XDP 配置为 y 不能证明驱动支持 zero-copy？

<details><summary>答案</summary>

1. DEBUG_INFO 是隐藏符号，需要选择具体 DWARF choice，并满足工具链依赖。
2. 它控制 drop monitor 的 netlink 告警服务；tracepoint 是另一接口。
3. AF_XDP socket 功能与驱动、队列、UMEM 的 zero-copy 支持属于不同层次。

</details>

## 与 DPDK/VPP 的对照

Kconfig 有点像编译期 feature 选项，但它会依据平台、工具版本和其他符号主动裁剪配置。与加载某个 PMD 的类比只覆盖“具备代码”这一层，不能替代设备能力和实际运行检查。
