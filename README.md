# linux-learning

内核阅读笔记 + out-of-tree 实验模块。**这个仓库里没有内核源码**，
源码在 `~/src/linux-*`，由一个共享的 `~/src/linux/.git` 用 worktree 管理。

## 目录

| 路径           | 放什么                                                      |
| -------------- | ----------------------------------------------------------- |
| `notes/`       | 阅读笔记，一条代码路径一篇，见 `notes/TEMPLATE.md`          |
| `modules/`     | out-of-tree 内核模块，每个子目录一个，能对多版本分别编译    |
| `patches/<ver>/` | 需要改内核本体时的 `git format-patch` 产物                |
| `configs/`     | kconfig 片段，`merge_config.sh` 合并进 defconfig             |
| `scripts/`     | 编译 / 起 QEMU / 加版本 的工具脚本                           |
| `experiments/` | netns、tc、bpftrace、selftest 之类的实验脚本                 |

## 日常流程

```bash
source env.sh 6.18          # 选定当前操作的内核版本 -> $KDIR
./scripts/kbuild.sh 6.18    # 首次：配置 + 编译 + 生成 compile_commands.json
make                        # 编译 modules/ 下所有模块
make matrix                 # 同一份模块在所有版本上编一遍，看 API 漂移
./scripts/run-qemu.sh 6.18  # 起虚拟机
./scripts/run-qemu.sh 6.18 --gdb   # 带 gdb stub，另开窗口 gdb $KDIR/vmlinux
```

## 改内核本体的规矩

不要在 worktree 里养长期分支。改完立刻导出成补丁，内核树随时能 reset 回干净：

```bash
cd $KDIR
# ...改代码...
git commit -am "trace: 在 __netif_receive_skb_core 打点"
git format-patch -1 -o ~/work/linux-learning/patches/6.18/
git reset --hard v6.18

# 要复现时
git am ~/work/linux-learning/patches/6.18/0001-*.patch
```

## 笔记里怎么引用代码

**不要写行号**（跨版本必漂）。写 `tag :: 文件 :: 函数名`：

    v6.18 net/core/dev.c :: __netif_receive_skb_core()

或贴 elixir 的带版本永久链接：https://elixir.bootlin.com/linux/v6.18/source/net/core/dev.c
