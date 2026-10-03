# 06 读内核代码：先找入口，再证明边

本篇回答：如何避免跟进几百个函数？怎样查 ops 的实际目标？clangd 与 git 历史分别能证明什么？
前置阅读：[02 系统调用](02-syscall-to-socket.md)、[05 编码惯用法](05-data-structures-and-idioms.md)。预计阅读时间：15 分钟。
源码基准：Linux v6.18；本篇命令默认源码目录为 `/home/chen/code/linux-lab/src/linux-6.18`。

## 每次只追一个具体问题

以“IPv4 stream socket 的 recvmsg 分派给谁”为例，先写清输入：原生 socket 接口、IPv4、stream、普通 TCP。不要同时研究所有协议族、所有错误码和所有内核配置。

自顶向下先找到 `net/socket.c:2269` 的 `__sys_recvfrom`，再跟到 `net/socket.c:1096` 的 `sock_recvmsg`。第一遍只记主路径的状态变化：用户缓冲区描述 → fd 对应文件 → socket → recvmsg 操作。

```c
if (unlikely(!sock))
    return -ENOTSOCK;
```

出处：`net/socket.c:2289`。第一遍可暂时跳过这条失败分支，但必须知道它是“类型不对而退出”，不能把失败分支里的清理当成成功路径。第二遍再把引用、锁和错误回收补齐；[05](05-data-structures-and-idioms.md) 中 `net/core/skbuff.c:699` 的 nodata 清理就是必须补读的例子。

阅读记录只需四列：函数、调用前条件、改变了什么、下一层问题。此时不必理解每个宏的全部实现。

## ops 跳转要找赋值，不靠名字猜

调用点 `net/socket.c:1078` 只告诉你使用 socket 的 recvmsg 成员。查赋值：

```sh
cd /home/chen/code/linux-lab/src/linux-6.18
rg -n 'recvmsg.*inet_recvmsg|inet_stream_ops|sock->ops =' net/ipv4/af_inet.c
rg -n 'recvmsg' net/socket.c
```

结果需要串成三条证据：

| 证据 | 源码 | 意义 |
|---|---|---|
| 协议类型项引用 `inet_stream_ops` | `net/ipv4/af_inet.c:1161` | 哪类 socket 选择此表 |
| `sock->ops = answer->ops` | `net/ipv4/af_inet.c:320` | 表真正赋给运行时对象 |
| `.recvmsg = inet_recvmsg` | `net/ipv4/af_inet.c:1071` | 表内成员指向哪个函数 |

不能仅凭搜到 `.recvmsg` 赋值就宣称所有 socket 都走它。这里还要读匹配 socket 类型与协议的条件。也不要把 DECLARE、定义、注册、调用四类搜索命中混为同一种证据。

运行时确认可用 bpftrace（BPF 跟踪语言）探测已经核对过的目标：

```sh
sudo bpftrace -l 'kprobe:inet_recvmsg'
sudo bpftrace -e 'kprobe:inet_recvmsg { @[comm] = count(); } interval:s:5 { exit(); }'
```

在这 5 秒内让实验机上的程序从 IPv4 socket 接收数据。计数增加证明这个运行场景到达过目标，但不证明所有 ops 分派都相同。若探针不可用，应检查内核和权限，不把“未观测到”写成“函数不会执行”。目标定义见 `net/ipv4/af_inet.c:875`；ftrace 的函数过滤示例在 [08](08-observation-tools.md)。上述运行时实验未实跑。

## compile_commands.json 与 clangd

clangd（C/C++ 语言服务）要知道当前配置下的 include 路径、宏和真实编译命令。仅用源码搜索可以找到文本；错误编译参数下的编辑器跳转却可能落到不适用的配置分支。

内核自带 `scripts/clang-tools/gen_compile_commands.py`，从已有构建的 `.cmd` 文件提取编译数据库，说明与参数见同文件 `:38`、`:44`、`:49`。**先有匹配 v6.18 配置的构建产物，才有有用的数据库。** 本篇不启动构建；实验环境篇负责准备构建目录。

```sh
KERNEL_SRC=/home/chen/code/linux-lab/src/linux-6.18
BUILD_DIR=/tmp/linux-6.18-build  # 改成已经构建过的输出目录
if test -f "$BUILD_DIR/.config"; then
    python3 "$KERNEL_SRC/scripts/clang-tools/gen_compile_commands.py" \
        -d "$BUILD_DIR" -o "$BUILD_DIR/compile_commands.json"
else
    echo '先准备匹配源码版本的内核构建目录' >&2
fi
```

检查数据库里是否真有需要阅读的翻译单元，不把空 JSON 当成成功。把编辑器中 clangd 的启动参数设为 `--compile-commands-dir=/tmp/linux-6.18-build`（使用实际目录），再从 `net/socket.c:1096` 跳转 `sock_recvmsg_nosec`。单文件诊断可用：

```sh
clangd --compile-commands-dir="$BUILD_DIR" --check="$KERNEL_SRC/net/socket.c"
```

`--check` 只验证解析，不能证明运行内核实际选择了某条分支。索引后仍用上节的注册关系和运行时证据确认。clangd 如何取得编译参数参见其[官方入门说明](https://clangd.llvm.org/installation)。本次核对了工具帮助及内核脚本参数，没有生成数据库或构建内核。

## git log 与 blame：把“动机”追到提交

```sh
cd /home/chen/code/linux-lab/src/linux-6.18
git describe --always --dirty --tags
git log --oneline -- net/socket.c
git blame -L 2269,2309 v6.18 -- net/socket.c
```

先从 blame 获取实际提交号，再执行 `git show <实际提交号> -- net/socket.c`；尖括号是说明，不要原样复制。`git log -S 'CLASS(fd, f)' -- net/socket.c` 可以寻找该字符串出现次数发生变化的提交。`git log -G 'sock_from_file' -- net/socket.c` 则按补丁行匹配，两者问题不同。

blame 表示最后修改这一行的提交，不保证是最初设计来源。格式整理、重命名与重构可能遮住原始动机；阅读提交说明和父提交差异后再下结论。源码只证明“现在怎样工作”；如果由行为推测设计理由，明确写“推测”，不要代作者补写动机。

本次已确认该源码仓库不是浅克隆。仓库有完整历史也不意味着所有邮件讨论都在本地；未实际访问的邮件、LWN 和论文不应出现在证据列表里。

## 动手：交付一张只有五个节点的图

画 `__sys_recvfrom → sock_recvmsg → sock_recvmsg_nosec → ops.recvmsg → inet_recvmsg`，给每条边写来源。特别标注最后一条边依赖 IPv4 stream 表的选择。第二遍补上 fd 作用域释放，再用 bpftrace 或 [08](08-observation-tools.md) 的 ftrace 记录一个实际命中。

## 要点回顾

- 先固定场景，自顶向下只追一个问题。
- 第一遍暂跳错误路径，第二遍必须补资源和锁。
- 函数指针需要注册、赋值、调用三类证据。
- 编辑器能解析，不等于运行内核经过该分支。
- 设计动机要查实际提交及讨论，推测必须标明。

## 自测

1. 搜到一个 recvmsg 的赋值就能确定所有 socket 的目标吗？
2. 为什么 gen_compile_commands.py 不能凭空生成完整编译参数？
3. blame 指向的提交一定是原始设计提交吗？
4. 一个探针没有命中，足够证明路径不存在吗？

<details><summary>答案</summary>

1. 不能，还要确认该场景选择了哪张操作表。
2. 它从既有 `.cmd` 构建记录提取参数，缺少产物就缺少证据。
3. 不一定，也可能是后来的整理或重构。
4. 不足够，还可能没有流量、目标被优化、探针不可用或运行版本不同。

</details>

## 与 DPDK/VPP 的对照

查 DPDK PMD ops、VPP node 注册关系的方法可以迁移到内核。但内核还多了架构入口、配置分支和多种执行上下文。你的第一张图应只保留当前场景实际需要的层，不以“图里出现更多函数”为阅读完成标准。
