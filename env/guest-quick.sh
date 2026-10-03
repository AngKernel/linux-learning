#!/usr/bin/env bash
# 只在 virtme 客户机中执行：配置 TAP 对端、SSH 和 iperf3；不安装软件。
set -euo pipefail
[[ $EUID == 0 && -f /run/ll-host/authorized_keys ]] || { echo '此脚本只由 up.sh 在 virtme 内调用' >&2; exit 1; }
id=${1:?VM ID}; [[ $id == 1 || $id == 2 ]] || exit 1
host_release=${2:?host kernel release}
[[ $host_release =~ ^[a-zA-Z0-9.+_-]+$ ]] || exit 1
# Ubuntu 的 perf/bpftool wrapper 依赖 uname -r；在 guest 临时 overlay 中使用实体二进制。
# /usr/local/bin 已由 up.sh 设置 overlay-rwdir，不会写回宿主。
for tool in perf bpftool; do
 real_tool=/usr/lib/linux-tools/$host_release/$tool
 if [[ -x $real_tool ]]; then
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_tool" > "/usr/local/bin/$tool"
  chmod 755 "/usr/local/bin/$tool"
 fi
done
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mac=52:54:00:18:00:0$id
iface=
for dev in /sys/class/net/*; do [[ $(cat "$dev/address") == "$mac" ]] && iface=${dev##*/}; done
[[ -n $iface ]] || { echo '没有找到实验 virtio_net 网卡' >&2; exit 1; }
ip link set lo up; ip link set "$iface" up; ip addr replace "192.0.2.$((10+id))/24" dev "$iface"
mkdir -p /run/sshd /run/ll
ssh-keygen -q -t ed25519 -N '' -f /run/ll/host_key
cat > /run/ll/sshd_config <<EOF
Port 22
ListenAddress 192.0.2.$((10+id))
HostKey /run/ll/host_key
PidFile /run/ll/sshd.pid
AuthorizedKeysFile /run/ll-host/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
SetEnv PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StrictModes no
Subsystem sftp internal-sftp
EOF
iperf3 -s > /run/ll/iperf.log 2>&1 &
# exec 后 virtme 生命周期随 sshd；宿主用 QMP 或客户机 poweroff 停机。
exec /usr/sbin/sshd -D -e -f /run/ll/sshd_config
