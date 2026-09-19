#!/usr/bin/env bash
# 做一个最小 busybox initramfs，给 run-qemu.sh 用。只需要跑一次。
# Debian/Ubuntu: sudo apt install busybox-static
set -euo pipefail

LEARN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$LEARN_ROOT/qemu/initramfs.cpio.gz"

bb="$(command -v busybox || true)"
[ -n "$bb" ] || { echo "找不到 busybox，装 busybox-static"; exit 1; }
if ldd "$bb" >/dev/null 2>&1; then
    echo "[!] $bb 是动态链接的，initramfs 里会缺 libc。请装 busybox-static。"
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"/{bin,sbin,proc,sys,dev,tmp,root,lib/modules}
cp "$bb" "$tmp/bin/busybox"
( cd "$tmp/bin" && ./busybox --install -s . )

cat > "$tmp/init" <<'EOF_INIT'
#!/bin/sh
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev 2>/dev/null
mount -t debugfs  none /sys/kernel/debug 2>/dev/null
mount -t tracefs  none /sys/kernel/tracing 2>/dev/null
ip link set lo up 2>/dev/null
echo
echo "=== initramfs 就绪: $(uname -r) ==="
echo "    模块在 /mnt（-virtfs 共享目录），insmod 直接用"
mkdir -p /mnt && mount -t 9p -o trans=virtio,version=9p2000.L share /mnt 2>/dev/null
exec /bin/sh
EOF_INIT
chmod +x "$tmp/init"

mkdir -p "$(dirname "$out")"
( cd "$tmp" && find . -print0 | cpio --null -o -H newc --quiet ) | gzip -9 > "$out"
echo "OK -> $out"
