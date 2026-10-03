#!/usr/bin/env bash
# 观察：perf 记录的 softirq/NAPI 事件时间序列。
# 运行：sudo traces/perf-rx.sh /tmp/rx.perf.data 10；perf script -i /tmp/rx.perf.data
# 预期：CPU、时间、softirq vector 和 napi work/budget 的逐事件记录。
set -euo pipefail
[[ ${1:-} == --help ]] && { echo 'perf-rx.sh 输出文件 [秒数=10]'; exit 0; }
out=${1:?请指定输出文件}; secs=${2:-10}
[[ $EUID == 0 && $secs =~ ^[1-9][0-9]*$ ]] || exit 2
[[ $(uname -r) =~ ^6\.18([.-]|$) ]] || { echo '请在实验 guest 运行' >&2; exit 1; }
[[ ! -e $out ]] || { echo "输出已存在：$out" >&2; exit 1; }
exec perf record -a -o "$out" -e irq:softirq_entry -e irq:softirq_exit -e napi:napi_poll -- sleep "$secs"
