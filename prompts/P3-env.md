背景：我在读 Linux 6.18 网络子系统源码（从未读过内核），需要一个能反复使用的实验环境：编译内核、启动虚拟机、用 virtio_net 收发流量、用 bpftrace / ftrace / perf 观察内核路径，必要时用 gdb 单步调试。
仓库：linux-learning（我的学习仓库），内核源码在 /home/chen/code/linux-lab/src/linux-6.18。环境相关内容放在 env/，追踪脚本放在 traces/。

第零步：先检查宿主机环境（发行版、是否支持 KVM、是否是 WSL2 或其他嵌套虚拟化），把结论写进 env/README.md，后续方案按实际环境调整。如果缺少依赖，列出安装命令，不要直接用 sudo 安装。

一、内核编译（env/build-kernel.sh）
- 以 defconfig 加 kvm_guest.config 为基础，再合并一个 env/kconfig/net-debug.config 片段，内容包括：BTF 调试信息（bpftrace 需要）、kprobes、ftrace 与 function_graph、BPF 相关选项、virtio_net、virtiofs/9p、GDB 脚本支持、网络丢包监控相关选项
- 每个配置项都要注释用途。配置项名称以 6.18 源码中的 Kconfig 为准，先 grep 确认是否存在，不存在的写明替代方案
- 生成 compile_commands.json，供 clangd 做代码跳转
- 支持增量编译；输出放在源码树之外（O= 目录）

二、启动虚拟机（两种方式都提供）
- 快速模式：用 virtme-ng 直接用宿主机的用户态启动新编译的内核，几秒内开机，适合反复改代码、做追踪实验
- 完整模式：Debian cloud image 加 QEMU/KVM，带持久化磁盘，适合需要完整系统的实验
- 两种方式的网络都要配 virtio_net：宿主机通过 tap 设备与虚拟机互通；另外提供一个"两台虚拟机经网桥互通"的拓扑脚本
- 共享目录：宿主机的 linux-learning 仓库挂载进虚拟机，脚本和笔记两边都能直接用
- 提供 env/up.sh、env/down.sh、env/ssh.sh 一键脚本

三、流量与调试工具
- 虚拟机内预装 bpftrace、bpftool、perf、iperf3、tcpdump、ss、ethtool
- env/traffic.sh：一条命令从宿主机向虚拟机发 TCP / UDP 流量（可以设定速率和时长），方便在追踪时稳定复现
- env/gdb.sh：用 QEMU 的 gdbstub 挂载内核调试，配好 vmlinux 和 lx- 系列辅助命令，写一个在网络收包函数上下断点的示例

四、追踪脚本库（traces/）
按我的学习主线组织，每个脚本开头注释写明：观察什么、怎么运行、预期输出长什么样。
- 收包路径：从硬中断、NAPI poll、GRO、协议分发、IP 层、TCP 接收，到唤醒用户进程，覆盖每个阶段的 kprobe 计数与耗时直方图
- ftrace function_graph 封装脚本：只追踪指定的函数子树，过滤噪声
- 丢包定位：按 drop reason 统计丢包
- 每个 CPU 的软中断分布、NAPI 每次 poll 处理的包数分布
- 所有被探测的函数名必须先在 6.18 源码中确认存在，并且不是 inline 函数（inline 的探测不到，需要换一个附近的探测点并说明原因）

五、自检
- env/selftest.sh：编译 → 启动 → 打流量 → 运行一个收包路径追踪脚本 → 检查输出非空，全流程自动跑一遍
- 完成后汇报：最终能跑通的流程、受宿主机环境限制没能实现的部分、我每次实验的标准操作步骤（不超过 5 步）
