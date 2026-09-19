#!/usr/bin/env bash
# 两个 netns + veth 对，最小的收发包实验场。
#   sudo ./veth-lab.sh up
#   sudo ip netns exec ns1 ping -c3 10.0.0.2
#   sudo ./veth-lab.sh down
set -euo pipefail

case "${1:-up}" in
up)
    ip netns add ns1; ip netns add ns2
    ip link add v1 type veth peer name v2
    ip link set v1 netns ns1; ip link set v2 netns ns2
    ip netns exec ns1 ip addr add 10.0.0.1/24 dev v1
    ip netns exec ns2 ip addr add 10.0.0.2/24 dev v2
    ip netns exec ns1 ip link set v1 up; ip netns exec ns1 ip link set lo up
    ip netns exec ns2 ip link set v2 up; ip netns exec ns2 ip link set lo up
    echo "ns1(10.0.0.1) <-> ns2(10.0.0.2) 就绪"
    ;;
down)
    ip netns del ns1 2>/dev/null || true
    ip netns del ns2 2>/dev/null || true
    echo "清理完成"
    ;;
esac
