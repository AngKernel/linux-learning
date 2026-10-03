#!/usr/bin/env bash
# 观察/运行：sudo traces/run.sh rx-path|rx-smoke|drop-reason|softirq-napi|irq [秒数]
# 预期：先看到 READY，再打印非空 map；drop-reason 没丢包时允许空。
set -euo pipefail
[[ ${1:-} == --help ]] && { echo 'run.sh rx-path|rx-smoke|drop-reason|softirq-napi|irq [秒数，默认 15]'; exit 0; }
name=${1:-rx-path}; secs=${2:-15}; dir=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $name =~ ^(rx-path|rx-smoke|drop-reason|softirq-napi|irq)$ && $secs =~ ^[1-9][0-9]*$ ]] || exit 2
[[ $EUID == 0 ]] || { echo '在 guest 内 sudo 执行' >&2; exit 1; }
[[ $(uname -r) =~ ^6\.18([.-]|$) ]] || { echo '请在本实验的 Linux 6.18 guest 运行' >&2; exit 1; }
command -v bpftrace >/dev/null || { echo '缺少 bpftrace' >&2; exit 1; }
python3 - "$(bpftrace --version)" <<'PYCHECK'
import re,sys
v=re.search(r'(\d+)\.(\d+)',sys.argv[1])
if not v or tuple(map(int,v.groups()))<(0,21): sys.exit('脚本以 bpftrace >= 0.21 的 args.field 语法编写；请升级 guest 工具')
PYCHECK
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
# 先列举每个精确探测点；源码有定义不等于编译后可探测。
while read -r probe; do
 if ! bpftrace -l "$probe" | grep -Fx "$probe" >/dev/null; then
  echo "不可用的探测点：$probe；见 SOURCES.md，检查 guest 配置/编译内联/模块" >&2; exit 1
 fi
done < <(sed -nE 's/^(kprobe|kretprobe|tracepoint):([^[:space:]{/]+).*/\1:\2/p' "$dir/$name.bt" | sort -u)
exec bpftrace -B line "$dir/$name.bt" "$secs"
