# patches

改内核本体的产物放这里，按版本分目录：`patches/6.18/0001-xxx.patch`。

导出：

```bash
cd $KDIR && git format-patch -1 -o ~/work/linux-learning/patches/6.18/
```

应用：

```bash
cd $KDIR && git am ~/work/linux-learning/patches/6.18/0001-*.patch
```

跨版本移植：在新版本的 worktree 里 `git am -3`，冲突的地方就是这段代码
在两个版本之间的差异，值得单独记一条笔记。
