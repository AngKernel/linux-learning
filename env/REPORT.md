# P3 环境交付报告

本篇回答：已交付什么、实际测过什么、还缺哪些验证？前置阅读：`README.md`。预计阅读时间：3 分钟。日期：2026-10-03，分支 `p3-env`。

## 完成内容

- 树外增量 Kbuild、defconfig/kvm_guest 合并、97 项带用途注释的调试/实验配置、配置生效校验、clangd compilation database、GDB 脚本、匹配模块安装目录。
- virtme-ng quick 模式和 Debian cloud/QEMU 完整模式；专用 TAP/bridge、两 VM IP、共享 `/work` 与只读 `/kernel-build`、SSH、公钥认证、持久 overlay、镜像 SHA512 校验。
- TCP/UDP 速率/时长发流；QEMU gdbstub、外置 vmlinux 与 lx 辅助命令；五步日常流程。
- 与 P8 配合的内置 veth、namespace、XDP sockets、CUBIC/BBR、netem、iptables/nftables。未编写用户态 TCP 协议栈实现。
- 自动 selftest 会验证内核版本、实验 MAC 对应 virtio_net、流量完成、GRO/TCP 探针非零计数，保留日志并停机。
- Ubuntu quick 用户态的 perf/bpftool wrapper 用 guest 临时 overlay 接到宿主已有实体；不会写宿主 `/usr/local/bin`。

## 实际验证及退出码

| 命令/检查 | 结果 |
|---|---|
| 内核 `git describe --always --dirty --tags` | exit 0，`v6.18`；完整历史；开工前已有未跟踪 `notes/` 被保留，本任务未写源码树 |
| 真实宿主发行版、设备和组只读检查 | Ubuntu 22.04.5，6.8.0-124；KVM/TUN 存在，用户属 kvm；`systemd-detect-virt` 输出 none，其 exit 1 表示未检测到虚拟化 |
| Python 打开 KVM，GET_API_VERSION、CREATE_VM 后关闭 | exit 0；API 12，创建成功；没有引导客户机 |
| 14 个 `.sh` 的 `bash -n` | exit 0，全部通过 |
| 所有公开 shell 入口 `--help` | exit 0；不会要求 sudo 或启动实验 |
| 97 个配置符号搜索实际 Kconfig | exit 0，全部存在；精确行号见 `KCONFIG-SOURCES.md` |
| `env/build-kernel.sh --check` | exit 1，缺 pahole；正确提前停止 |
| `LL_STATE=/tmp/ll-p3-selftest-check env/selftest.sh quick 1` | exit 1，编译前置检查缺 pahole；没有启动 VM 或创建网桥 |
| 替换为临时 mock 的 `env/traffic.sh udp 5M 7 2` | exit 0，参数准确转发到 .12、7 秒、5M、UDP；没有真实发包 |
| `env/traffic.sh nonsense` | exit 1，拒绝非法协议，未发流 |
| 普通用户 `env/topology.sh up 1000` | exit 1，提示 root/CAP_NET_ADMIN；未改网络 |
| 普通用户 `traces/run.sh rx-smoke 1` | exit 1，拒绝在宿主误跑 |
| 宿主 `env/guest-quick.sh 1` | exit 1，拒绝在 guest 标记不存在时执行 |

另做本地 Markdown 链接检查、shell 内嵌 Python 语法检查和三个源码引用抽查；没有使用 shellcheck（未安装）。BPF 文件只做源码/接口与分隔符检查，**不宣称通过 bpftrace parser、verifier 或真实挂载**。

## 未完成/未确认

**没有跑通完整的“编译 → VM → 流量 → 追踪”流程。** 根因是缺 pahole、virtme-ng、bpftrace、cloud-localds；按要求只列安装命令，没有安装依赖。真实宿主支持 KVM，不能把沙箱中的设备不可见写成宿主硬件限制。

未实跑：olddefconfig 最终依赖闭包、全内核编译、compile database 生成、两种 VM 引导、cloud image 下载/分区/cloud-init、共享目录、SSH、两机互通、GDB 断点、全部 tracing 工具和自动 selftest 成功路径。默认 cloud 根分区 `/dev/vda1` 待镜像实查。quick 的“几秒启动”未计时。脚本具备可检查入口，不等于已通过集成测试。

当前 Ubuntu bpftrace 候选 0.14，追踪库要求 ≥0.21；cloud 安装版本满足所查文档范围，但安装结果仍需实际验证。perf/bpftool 宿主实体与 guest 6.18 新特性兼容性亦待验。

## 用户关注和后续验收

安装依赖后优先运行 `env/selftest.sh cloud 1`，再验证 quick。按 README 中不超过五步的操作重现，保留 console/traffic/trace 日志。固定镜像与工具版本、宿主已有防火墙兼容性、模块/perf 选择已汇总到 `OPEN-QUESTIONS.md`。

P9 优先检查：legacy iptables 的两个新增依赖、所有 `=y` 最终值、virtme-ng 参数兼容性、Debian 首启和 root 分区、source-defined 非 inline 函数是否真正可探测、计数单位与 BPF map 并发解释。
