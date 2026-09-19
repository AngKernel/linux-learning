#!/usr/bin/env bash
# 配置 + 编译某个版本的内核，并生成 clangd 用的 compile_commands.json
#   ./scripts/kbuild.sh 6.18
#   ./scripts/kbuild.sh 6.18 reconfig    # 丢掉现有 .config 重新生成
set -euo pipefail

ver="${1:?用法: kbuild.sh <版本，如 6.18> [reconfig]}"
mode="${2:-}"
LEARN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KSRC_ROOT="${KSRC_ROOT:-$HOME/src}"
KDIR="$KSRC_ROOT/linux-$ver"

[ -d "$KDIR" ] || { echo "没有 $KDIR，先 ./scripts/newver.sh v$ver"; exit 1; }
cd "$KDIR"

if [ "$mode" = "reconfig" ]; then rm -f .config; fi

if [ ! -f .config ]; then
    echo "==> 生成 .config"
    make defconfig
    # x86 的最小虚拟机配置，砍掉一大堆真实硬件驱动，编译快很多
    make kvm_guest.config 2>/dev/null || echo "    (这个版本没有 kvm_guest.config，跳过)"
    ./scripts/kconfig/merge_config.sh -m .config "$LEARN_ROOT/configs/learn.config"
    make olddefconfig
fi

echo "==> 编译（$(nproc) 并发）"
make -j"$(nproc)"

echo "==> 生成 compile_commands.json"
if [ -x ./scripts/clang-tools/gen_compile_commands.py ]; then
    ./scripts/clang-tools/gen_compile_commands.py
    echo "    OK -> $KDIR/compile_commands.json"
else
    echo "    这个版本没有 gen_compile_commands.py（太老），改用 cscope："
    make ARCH=x86 COMPILED_SOURCE=1 cscope
fi

echo
echo "完成。bzImage: $KDIR/arch/x86/boot/bzImage"
echo "用编辑器直接打开 $KDIR，clangd 会自动读 compile_commands.json。"
