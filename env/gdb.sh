#!/usr/bin/env bash
# 用法：env/gdb.sh [1|2]；配合 PAUSE=1 env/up.sh quick 1，hbreak tcp_v4_rcv。
source "$(dirname -- "$0")/common.sh"
[[ ${1:-} == --help ]] && { echo 'gdb.sh [1|2]；示例：hbreak tcp_v4_rcv / continue / bt / lx-dmesg'; exit 0; }
init_state; vm_vars "${1:-1}"; check_source; need gdb
[[ -f $BUILD_DIR/vmlinux && -e $BUILD_DIR/vmlinux-gdb.py ]] || fail '先构建 vmlinux 和 scripts_gdb'
# 使用 -iex 在加载 vmlinux 前设置 safe-path；仅信任本次内核的脚本目录。
exec gdb -iex "add-auto-load-safe-path $KERNEL_SRC/scripts/gdb" \
 -iex "add-auto-load-safe-path $BUILD_DIR" -ex "directory $KERNEL_SRC" \
 -ex "target remote 127.0.0.1:$GDB_PORT" "$BUILD_DIR/vmlinux"
