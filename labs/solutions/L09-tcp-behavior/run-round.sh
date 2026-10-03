#!/usr/bin/env bash
# Usage: sudo bash run-round.sh IF cubic|bbr clear|netem SECONDS /tmp/OUTPUT
# Requires a fresh lab-owned root fq with handle 109:. Static checks only; UNTESTED in VM.
set -euo pipefail
iface=${1:-}; algo=${2:-}; condition=${3:-}; seconds=${4:-30}; out=${5:-}
[[ $EUID == 0 && $(uname -r) =~ ^6\.18([.-]|$) ]] || { echo 'Requires root in the v6.18 guest' >&2; exit 2; }
[[ $iface =~ ^[[:alnum:]_.:-]+$ && $algo =~ ^(cubic|bbr)$ && $condition =~ ^(clear|netem)$ ]] || exit 2
[[ $seconds =~ ^[1-9][0-9]*$ && ${#seconds} -le 3 && $seconds -le 600 && $out == /tmp/* ]] || exit 2
for tool in ip tc ss sysctl iperf3; do command -v "$tool" >/dev/null; done
peer=192.0.2.12
route_if=$(ip route get "$peer" | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
[[ $route_if == "$iface" ]] || { echo "Route uses $route_if, not $iface" >&2; exit 2; }
available=$(sysctl -n net.ipv4.tcp_available_congestion_control)
[[ " $available " == *" $algo "* ]] || { echo "Algorithm unavailable: $algo" >&2; exit 2; }
tc qdisc show dev "$iface" | awk '$1=="qdisc" && $2=="fq" && $3=="109:" && $4=="root" {ok=1} END {exit !ok}' || {
  echo 'Requires the explicitly prepared lab root fq 109:; refusing another qdisc' >&2; exit 2;
}
[[ ! -e $out ]] || { echo 'Choose a new output directory for each round' >&2; exit 2; }
mkdir -p -- "$out"
old_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
printf '%s\n' "$old_cc" > "$out/cc-before.txt"
tc -s qdisc show dev "$iface" > "$out/qdisc-before.txt"
observer_pid=
restore() {
  rc=$?
  trap - EXIT
  touch "$out/stop-observer"
  if [[ -n $observer_pid ]]; then wait "$observer_pid" || rc=1; fi
  sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" || rc=1
  tc qdisc replace dev "$iface" root handle 109: fq || rc=1
  { sysctl net.ipv4.tcp_congestion_control; tc -s qdisc show dev "$iface"; } > "$out/restored.txt"
  if ((rc != 0)); then echo 'Round or cleanup failed; inspect restored.txt and restore manually if needed' >&2; fi
  exit "$rc"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sysctl -w "net.ipv4.tcp_congestion_control=$algo"
if [[ $condition == netem ]]; then
  tc qdisc replace dev "$iface" root handle 209: netem delay 20ms loss 0.5% limit 10000
fi
tc -s qdisc show dev "$iface" > "$out/qdisc-during.txt"
(
  for ((i=0;i<seconds*2+4;i++)); do
    [[ ! -e $out/stop-observer ]] || break
    date +%s.%N
    ss -tin '( sport = :5229 or dport = :5229 )'
    sleep 0.5
  done
) > "$out/ss.txt" &
observer_pid=$!
iperf3 -c "$peer" -p 5229 -t "$seconds" -P 1 -b 50M | tee "$out/iperf.txt"
tc -s qdisc show dev "$iface" > "$out/qdisc-after.txt"
