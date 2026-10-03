# P3 待决定与待验证事项

本篇回答：运行前还有哪些选择、哪些结论尚无实测？前置阅读：`README.md`、`REPORT.md`。预计阅读时间：2 分钟。以下事项不阻塞交付脚本，没有中途等待确认。

1. **快速模式 bpftrace 来源**：宿主 Ubuntu 22.04 候选是 0.14，本库要求 ≥0.21。建议优先使用 cloud 的新版工具，或用户选定官方 release/本地构建版本用于 quick；未自动安装。
2. **Debian 镜像固定版本**：默认 latest 便于启动但会变化。请选一个固定发布版本或校验过的本地 `BASE_IMAGE`。本次未下载镜像，root 分区默认 `/dev/vda1` 尚需检查。
3. **宿主桥接规则**：实际宿主已有 Docker、libvirt 网桥。实验桥名称独立，脚本不改全局防火墙；若 guest1/guest2 不通，应按现有规则诊断并由用户决定最小放行策略。
4. **首轮完整验收**：安装缺项后运行 cloud selftest，再验证 quick。检查 config 实際生效、9p、cloud-init、SSH、11 个探针、function_graph、GDB，保留工具版本及输出。此项为未完成验证，不是已经通过的结果。
5. **模块与 perf**：P8 L06 使用本次外置 BUILD_DIR，不能使用宿主 6.8 模块目录。quick 已绕过 Ubuntu 的版本选择 wrapper，但宿主 perf/bpftool 实体与 6.18 新特性的兼容性待验；是否额外编译 `tools/perf` 由用户决定。

本次无需替用户决定 KVM/TCG：真实宿主 KVM 创建已通过，默认使用 KVM。不会生成用户态 TCP 协议栈实现。
