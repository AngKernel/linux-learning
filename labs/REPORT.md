# P8 交付报告

日期：2026-10-03。任务分支：`p8-labs`；worktree：`/home/chen/code/linux-lab/ll-p8`。只修改 `labs/`，阶段提交均以 `P8: ` 开头；没有修改笔记、根 README 或 AGENTS。源码只读基准 `/home/chen/code/linux-lab/src/linux-6.18`，多次 `git describe --always --dirty --tags` 均为 `v6.18`。

## 完成内容

已交付十个实验题面、对应参考答案与原创非 TCP 栈示例，合计 **36 个文件：24 个 Markdown、4 个 C/BPF C、3 个 bpftrace、2 个 shell、2 个 Python 和 1 个 Kbuild Makefile**。其中 34 个新增、2 个原占位索引更新。文件与建议顺序见 [README.md](README.md) 和 [solutions/README.md](solutions/README.md)。题面每篇包含问题/前置/时间、目标、条件、步骤、验收、3–5 道思考题、分层提示与 DPDK/VPP 对照；答案统一放 solutions。

| 实验 | 已交付资料 | 主要边界 |
|---|---|---|
| L01 | function_graph、kprobe 阶段追踪、ICMP 抓包对应 | GRO inline 入口改用可探候选；单包/list 双入口；不是逐包完整关联器 |
| L02 | NAPI/softirq 分组直方图、budget 保存恢复、coalescing 能力分支 | 单 poll weight 不等于全轮 netdev_budget；不保证设备支持 usecs |
| L03 | 普通 AF_PACKET C 抓包、tcpdump 对照 | tap 副本/方向/截断与 offload；不是 PMD |
| L04 | raw socket 人工逐包 SYN/ACK/GET/响应/FIN，RST 对照，字段推导 | 不提供 TCP 状态机或可执行握手客户端；IPv4 HDRINCL 自动补头边界已说明 |
| L05 | TUN ICMP Echo 原创 C 程序和 sink 模式 | 仅无 options、未分片、目标 `.2` 的 IPv4 Echo；校验长度与 checksum |
| L06 | netfilter 原创模块、Kbuild、五 hook×三路径矩阵 | 只注册 init_net；安全取头；必须目标 6.18 BUILD_DIR；不逐包 printk |
| L07 | XDP count/drop 同源变体、map 统计、INPUT 对照 | 限定无 VLAN 未分片 IPv4 UDP/9000；先 UDP 建流再 DROP；稳定窗口统计 |
| L08 | xdp-bench AF_XDP 收包/反射、copy/zero-copy、原创 ICMP 发流与 RTT | queue 绑定、协商能力、同端时钟；TUN 与 L2 反射的工作不同 |
| L09 | CUBIC/BBR 四轮控制条件、netem/ss、自动恢复 helper | 新建流验证算法；root fq/netem 不叠加；基线只恢复实验自己拥有的 qdisc |
| L10 | TCP 状态/重传 tracepoint、一次性普通内核 socket 应用 | request/child/TIME_WAIT 对象分开；重传事件保留 err，不伪造教材状态序列 |

L04 的“手工练习”由读者填写十六进制 packet 文件、现成 socat 注入；提供字段和序号推导，不提供自动 TCP 协议实现。L10 的 Python 只调用内核 SOCK_STREAM，是普通测试应用。其余四个 C/BPF 示例以及 L08 的 ICMP/Ethernet 工具均为本任务原创，没有提交第三方源码或编译产物。

## 已执行的检查

| 检查 | 结果与实际覆盖 |
|---|---|
| AF_PACKET/TUN C | 宿主 GCC，`-std=c11 -Wall -Wextra -Werror -O2` 编译通过；输出在 `/tmp`。不代表 guest raw socket/TUN 已运行 |
| XDP count/drop | clang 14，`-target bpf -O2 -g -Wall -Wextra -Werror`，v6.18 tools UAPI，两变体编译为 eBPF ELF；未提交 `.o` |
| TUN 离线安全检查 | 独立只读审查者构造 0/17/18 字节 payload 的正常回复及 12 个拒绝且不修改输入案例，ASan/UBSan 通过；LeakSanitizer 因沙箱 ptrace 限制关闭 |
| L08 离线包检查 | 20/21/64/1400 字节 payload，IP/ICMP checksum、反射/真实 Echo reply 识别、截断/篡改/错 payload/错 MAC 拒绝均通过 |
| Shell/Python | 两个 shell helper 的 `bash -n`；两个 Python 脚本的语法编译通过；辅助核对的 26 个 Bash 文档块、整合后全部 44 个 Bash 文档块均通过 `bash -n`，对应 BPF args 字段已逐事件核对；cache 输出到 `/tmp`。不在宿主执行 sysctl/qdisc 修改 |
| 源码事实 | AF_PACKET/TUN/netfilter/XDP/AF_XDP、raw RST、NAPI 预算、CC 与 TCP tracepoint 字段按 v6.18 核对；引用的源路径/行号自动检查存在且未越界 |
| 引用与链接 | 本地链接检查；P8 旧基线中未带入的笔记/环境文件用已合并的 main 校验，合并后可解析 |
| 仓库范围 | 完整分支 `git diff --check c51a94c..HEAD`，变更均在 labs；没有 pcap、第三方源码、目标文件或用户态 TCP 栈代码 |

独立示例审查记录由调度保存于 `/home/chen/code/linux-lab/ll-logs/P8-example-review.txt`；这是本次执行日志，不是仓库内实验结果。L01/L02/L09/L10 的源码核对与题面由只读辅助随后在限定子目录协作完成，Git 始终由 P8 统一提交。

检查中修正的具体问题：

- clang BPF 的 `license` section 与同名全局符号发生冲突，改成 `lab_license` 后两个变体编译通过。
- iperf3 除 TCP control 还有 UDP 建流交互；先装全 UDP DROP 会阻断发流。L07 改为先稳定发送，再中途加 DROP，排除转换期并只采固定 15 秒窗口。
- raw IPPROTO_RAW 使用 HDRINCL，内核重填 IPv4 total length/checksum；补充该限制，保留 TCP checksum 手工责任。
- L09 的 netem 使用独立 handle `209:`，fq 基线为 `109:`，避免不同 kind 复用同一 handle 的修改路径问题；恢复回明确拥有的 fq 基线。

## 未完成的运行验收、未确认项

**十个 VM 实验的完整端到端运行均未执行。** 没有实际性能数字，没有把编译成功说成 BPF verifier 成功，也没有把源码函数存在说成驱动能力已协商。

1. P3 环境构建仍受 pahole 等缺失依赖限制；本任务没有安装依赖、启动 VM、加载模块/XDP，或调整宿主管理网络。
2. netfilter 模块尚未用实际 6.18 BUILD_DIR 完成目标编译、加载、功能/卸载验证。不能使用宿主 6.8 模块树替代。
3. bpftrace 尚未进行动态编译、挂载和流量验收。题面沿用 P3 的 ≥0.21 门槛，P2 示例用 0.24；实际选定版本与跨版本兼容仍需验证。
4. XDP verifier、native/generic 挂载与 AF_XDP copy/zero-copy 均未执行。virtio pool enable 存在，但 queue/headroom/设备与 QEMU 特性可能导致失败；题面保留错误与替代分支。
5. L08 的 xdp-tools 未安装；`xsk-drop`/`xsk-tx` 选项按访问到的上游手册设计，必须固定本机版本并检查 CLI。其接管整队列可能暂断数据 SSH，题面提供有界后台运行和清理方式，仍需在 guest 实测。
6. coalescing 支持、实际软中断 CPU 分布、NAPI work、CC 行为、RTT/吞吐均待测。L08 的 Python 发流器可能先达到上限；不能据此给出 AF_XDP 的容量上限。
7. TUN ICMP 与 AF_XDP L2 反射是整体路径对照；不能把差值全部归因于一次复制，也没有测跨 VM 单向入口时延。

## 用户需要关注与后续顺序

完整待决表在 [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md)。建议先补齐 P3 环境并固定 bpftrace/xdp-tools 版本，按 L01→L03→L05 验证最小闭环，然后验 L06 目标模块与清理，再做 L07/L08 低速正确性，最后做性能与 TCP 观测。每题保存命令版本、探针发现结果、真实日志、参数恢复结果；没有观察到事件时保留“未触发/未覆盖/不可用”的区别。

P9 优先拆成三组核查：入口/执行上下文组（L01/L02/L03），包构造与 hook/所有权组（L04/L05/L06/L07/L08），TCP 实例/状态组（L09/L10）。重点是 L04 序号与关闭、L06 namespace、L07 建流与稳定窗口、L08 queue/UMEM 和不同回程工作、L10 request/child/TIME_WAIT 身份。

推荐调度抽查的 v6.18 锚点：

- `net/core/dev.c:7580`：poll 的 weight 与 `napi_poll` 的预算口径。
- `net/ipv4/raw.c:399`：HDRINCL 重填 IPv4 长度/checksum。
- `include/linux/skbuff.h:4298`：netfilter 示例安全取头 helper。
- `drivers/net/virtio_net.c:5932`：AF_XDP pool headroom 约束。
- `include/trace/events/tcp.h:16`：普通重传事件含 err，没有 protocol/rto。
- `net/ipv4/tcp.c:5000`：旧完整 socket 的 CLOSE，与 TIME_WAIT 新对象区分。
