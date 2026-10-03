#!/usr/bin/env bash
# 观察：一个函数及其同步调用子树，独立 tracefs instance 避免清空其他会话。
# 运行：sudo traces/function-graph.sh virtnet_poll 5 8 > /tmp/rx.graph
# 预期：带 CPU、函数括号和持续时间的 function_graph 文本；并行打流量。
# 核对：Documentation/trace/ftrace.rst:340；函数表见 SOURCES.md。
set -euo pipefail
[[ ${1:-} == --help ]] && { echo 'function-graph.sh 函数 [秒数=5] [最大深度=8]'; exit 0; }
fn=${1:-virtnet_poll}; secs=${2:-5}; depth=${3:-8}
[[ $EUID == 0 && $fn =~ ^[a-zA-Z_][a-zA-Z_0-9.]*$ && $secs =~ ^[1-9][0-9]*$ && $depth =~ ^[1-9][0-9]*$ ]] || exit 2
[[ $(uname -r) =~ ^6\.18([.-]|$) ]] || { echo '仅用于实验的 6.18 guest' >&2; exit 1; }
base=/sys/kernel/tracing
mountpoint -q "$base" || mount -t tracefs tracefs "$base"
awk '{print $1}' "$base/available_filter_functions" | grep -Fx "$fn" >/dev/null || { echo "ftrace 不可见：$fn" >&2; exit 1; }
inst=$base/instances/ll-graph-$$; mkdir "$inst"
cleanup() { echo 0 > "$inst/tracing_on"; echo nop > "$inst/current_tracer"; rmdir "$inst"; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
echo 0 > "$inst/tracing_on"
echo function_graph > "$inst/current_tracer"
echo "$fn" > "$inst/set_graph_function"
echo "$depth" > "$inst/max_graph_depth"
echo 4096 > "$inst/buffer_size_kb"
echo funcgraph-cpu > "$inst/trace_options"
echo funcgraph-duration > "$inst/trace_options"
echo 1 > "$inst/tracing_on"
sleep "$secs"
echo 0 > "$inst/tracing_on"
cat "$inst/trace"
# 同时报告 ring buffer overrun；输出是最近一段记录，不保证整个区间完整。
cat "$inst"/per_cpu/cpu*/stats >&2
