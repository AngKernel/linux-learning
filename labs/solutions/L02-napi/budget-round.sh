#!/usr/bin/env bash
# Change only net.core.netdev_budget in a disposable v6.18 guest; restore on exit.
# Static syntax checked; VM execution and load UNTESTED.
set -euo pipefail
budget=${1:-}; seconds=${2:-25}
[[ $EUID == 0 ]] || { echo 'Run in the guest with sudo bash' >&2; exit 2; }
[[ $(uname -r) =~ ^6\.18([.-]|$) ]] || { echo 'Requires the v6.18 guest' >&2; exit 2; }
[[ $budget =~ ^[1-9][0-9]*$ && $seconds =~ ^[1-9][0-9]*$ ]] || exit 2
command -v bpftrace >/dev/null
base=$(cd -- "$(dirname -- "$0")" && pwd)
old_budget=$(sysctl -n net.core.netdev_budget)
restore() {
  if ! sysctl -w "net.core.netdev_budget=$old_budget"; then
    echo "RESTORE FAILED: manually restore net.core.netdev_budget=$old_budget" >&2
    return 1
  fi
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sysctl -w "net.core.netdev_budget=$budget"
sysctl net.core.netdev_budget net.core.netdev_budget_usecs
bpftrace -B line "$base/napi.bt" "$seconds"
