#!/usr/bin/env bash
# 起一台跑自编译内核的虚拟机
#   ./scripts/run-qemu.sh 6.18
#   ./scripts/run-qemu.sh 6.18 --gdb    # 停在第一条指令等 gdb 接管
#
# 退出：Ctrl-A 然后按 x
set -euo pipefail

ver="${1:?用法: run-qemu.sh <版本> [--gdb]}"
shift || true
LEARN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KSRC_ROOT="${KSRC_ROOT:-$HOME/src}"
KDIR="$KSRC_ROOT/linux-$ver"
bz="$KDIR/arch/x86/boot/bzImage"
initrd="$LEARN_ROOT/qemu/initramfs.cpio.gz"

[ -f "$bz" ]     || { echo "没有 $bz，先 ./scripts/kbuild.sh $ver"; exit 1; }
[ -f "$initrd" ] || { echo "没有 $initrd，先 ./scripts/mkinitramfs.sh"; exit 1; }

extra=()
append="console=ttyS0 panic=1 nokaslr"
if [ "${1:-}" = "--gdb" ]; then
    extra+=(-s -S)
    cat <<EOF_TIP

另开一个窗口：
    cd $KDIR
    gdb vmlinux
    (gdb) target remote :1234
    (gdb) b __netif_receive_skb_core
    (gdb) c
内核自带的 gdb 脚本（lx-dmesg / lx-ps / lx-symbols）需要在 ~/.gdbinit 里加：
    add-auto-load-safe-path $KDIR/scripts/gdb/vmlinux-gdb.py

EOF_TIP
fi

if [ -w /dev/kvm ]; then extra+=(-enable-kvm -cpu host); fi

exec qemu-system-x86_64 \
    -kernel "$bz" \
    -initrd "$initrd" \
    -append "$append" \
    -m 2G -smp 2 -nographic -no-reboot \
    -virtfs "local,path=$LEARN_ROOT,mount_tag=share,security_model=none" \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    "${extra[@]}"
