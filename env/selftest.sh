#!/usr/bin/env bash
# 用法：env/selftest.sh [quick|cloud] [1|2]；先安装依赖和显式建立 TAP 网桥。
# 编译 -> 启动 -> 确认 guest/virtio_net -> 后台追踪 -> 流量 -> 验证真实计数。
source "$(dirname -- "$0")/common.sh"
[[ ${1:-} == --help ]] && { echo 'selftest.sh [quick|cloud] [1|2]；运行前先 topology.sh up；结束自动停 VM'; exit 0; }
mode=${1:-quick}; [[ $mode == quick || $mode == cloud ]] || fail '模式必须 quick/cloud'
init_state; vm_vars "${2:-1}"
[[ ! -e $VM_DIR/qmp.sock ]] || fail '自检使用空闲 VM ID，避免停掉现有实验'
"$ENV_DIR/build-kernel.sh"
[[ $mode != cloud ]] || "$ENV_DIR/prepare-cloud.sh" "$VM_ID"
started=0; trace_pid=
cleanup() {
 [[ -z $trace_pid ]] || { kill "$trace_pid" 2>/dev/null || true; wait "$trace_pid" 2>/dev/null || true; }
 [[ $started != 1 ]] || "$ENV_DIR/down.sh" "$VM_ID"
}
trap cleanup EXIT
started=1; "$ENV_DIR/up.sh" "$mode" "$VM_ID"
ready=0
for ((i=0;i<120;i++)); do
 if "$ENV_DIR/ssh.sh" "$VM_ID" true >/dev/null 2>&1; then ready=1; break; fi
 sleep 2
done
[[ $ready == 1 ]] || fail "SSH 未就绪，查看 $VM_DIR/console.log"
if [[ $mode == cloud ]]; then
 "$ENV_DIR/ssh.sh" "$VM_ID" 'sudo cloud-init status --wait'
fi
# 针对 MAC 找实验网卡，避免 cloud 的第二张下载用网卡混淆。
"$ENV_DIR/ssh.sh" "$VM_ID" "test \"\$(uname -r | cut -d. -f1,2)\" = 6.18 && for d in /sys/class/net/*; do if [ \"\$(cat \"\$d/address\")\" = $MAC ]; then ethtool -i \"\${d##*/}\"; fi; done" > "$VM_DIR/driver.log"
grep -q '^driver: virtio_net$' "$VM_DIR/driver.log" || fail '未确认实验网卡为 virtio_net'
"$ENV_DIR/ssh.sh" "$VM_ID" 'sudo /work/traces/run.sh rx-smoke 20' > "$VM_DIR/selftest-trace.log" 2>&1 &
trace_pid=$!
ready=0
for ((i=0;i<40;i++)); do
 if grep -q '^READY rx-smoke' "$VM_DIR/selftest-trace.log"; then ready=1; break; fi
 kill -0 "$trace_pid" 2>/dev/null || break
 sleep 1
done
[[ $ready == 1 ]] || fail '探针没有成功挂载；查看 selftest-trace.log'
"$ENV_DIR/traffic.sh" tcp 20M 5 "$VM_ID" > "$VM_DIR/selftest-traffic.log"
wait "$trace_pid"; trace_pid=
for fn in gro_receive_skb tcp_v4_rcv; do
 grep -Eq "^@calls\\[$fn\\]: [1-9][0-9]*$" "$VM_DIR/selftest-trace.log" || fail "缺少 $fn 非零计数"
done
echo "PASS：编译、启动、TCP 流量、GRO/TCP 探针非零；日志 $VM_DIR/selftest-{trace,traffic}.log"
