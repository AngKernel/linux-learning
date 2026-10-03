#!/usr/bin/env bash
# 用法：env/traffic.sh [tcp|udp] [速率，例如 20M] [秒数] [VM ID]。
source "$(dirname -- "$0")/common.sh"
[[ ${1:-} == --help ]] && { echo 'traffic.sh [tcp|udp] [速率，默认 20M] [秒数，默认 10] [1|2]'; exit 0; }
proto=${1:-tcp}; rate=${2:-20M}; duration=${3:-10}; vm_vars "${4:-1}"
[[ $proto == tcp || $proto == udp ]] || fail '协议仅 tcp/udp'
[[ $rate =~ ^[0-9]+([.][0-9]+)?[KMG]?$ && $duration =~ ^[1-9][0-9]*$ ]] || fail '速率或时长格式错误'
need iperf3
args=(-c "$VM_IP" -t "$duration" -b "$rate" --get-server-output)
[[ $proto != udp ]] || args+=(-u)
exec iperf3 "${args[@]}"
