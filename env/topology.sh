#!/usr/bin/env bash
# 用法：sudo env/topology.sh up UID / down；仅管理有专属 alias 的 llbr0/lltap{1,2}。
set -euo pipefail
[[ ${1:-} == --help ]] && { echo 'sudo topology.sh up UID | down；建立 192.0.2.0/24 隔离网桥'; exit 0; }
[[ $EUID == 0 ]] || { echo '需要 root/CAP_NET_ADMIN；请显式 sudo 执行' >&2; exit 1; }
[[ -c /dev/net/tun ]] || { echo '/dev/net/tun 不存在；请在宿主检查 tun 驱动/设备映射' >&2; exit 1; }
owner=linux-learning:P3
owned() { [[ -e /sys/class/net/$1 ]] && [[ $(cat "/sys/class/net/$1/ifalias") == "$owner" ]]; }
for dev in llbr0 lltap1 lltap2; do
 if [[ -e /sys/class/net/$dev ]] && ! owned "$dev"; then echo "拒绝修改已有非本脚本设备 $dev" >&2; exit 1; fi
done
case ${1:-} in
 up)
 uid=${2:-${SUDO_UID:-}}; [[ $uid =~ ^[0-9]+$ ]] || { echo '请指定运行 QEMU 的 UID' >&2; exit 1; }
 if ! owned llbr0; then ip link add llbr0 type bridge; ip link set llbr0 alias "$owner"; fi
 ip addr replace 192.0.2.1/24 dev llbr0; ip link set llbr0 up
 for dev in lltap1 lltap2; do
  if ! owned "$dev"; then ip tuntap add dev "$dev" mode tap user "$uid"; ip link set "$dev" alias "$owner"; fi
  ip link set "$dev" master llbr0; ip link set "$dev" up
 done
 ;;
 down)
 # 先用 down.sh 停 VM；这里不触碰宿主原有桥、路由或防火墙。
 for dev in lltap1 lltap2 llbr0; do if owned "$dev"; then ip link delete "$dev"; fi; done
 ;;
 *) echo '用法：sudo topology.sh up UID | down' >&2; exit 1;;
esac
