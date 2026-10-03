#!/usr/bin/env bash
# 被宿主脚本 source；所有产物默认在仓库和内核源码之外。
set -euo pipefail
ENV_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$ENV_DIR/.." && pwd)
KERNEL_SRC=${KERNEL_SRC:-/home/chen/code/linux-lab/src/linux-6.18}
LL_STATE=${LL_STATE:-${XDG_CACHE_HOME:-$HOME/.cache}/linux-learning}
BUILD_DIR=${BUILD_DIR:-$LL_STATE/build-6.18}
fail() { echo "错误：$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "缺少 $1；见 env/README.md 的依赖安装命令"; }
check_source() {
 [[ -d $KERNEL_SRC ]] || fail "内核目录不存在：$KERNEL_SRC"
 local version; version=$(git -C "$KERNEL_SRC" describe --always --dirty --tags)
 [[ $version == v6.18 ]] || fail "源码应是干净的 v6.18，当前 $version"
}
init_state() {
 umask 077
 mkdir -p "$LL_STATE"
 LL_STATE=$(realpath "$LL_STATE")
 # QEMU 的 key=value 路径参数不接受逗号；同时避免脚本和 GDB 路径歧义。
 for path in "$LL_STATE" "$REPO" "$KERNEL_SRC" "$BUILD_DIR"; do
   [[ $path != *[[:space:],\'\"]* ]] || fail "当前脚本要求路径不含空白、逗号和引号：$path"
 done
 export LL_STATE BUILD_DIR KERNEL_SRC
}
vm_vars() {
 VM_ID=${1:-1}; [[ $VM_ID == 1 || $VM_ID == 2 ]] || fail "VM ID 只能为 1 或 2"
 VM_DIR=$LL_STATE/vm$VM_ID; VM_IP=192.0.2.$((10+VM_ID)); TAP=lltap$VM_ID
 MAC=52:54:00:18:00:0$VM_ID; UPLINK_MAC=52:54:00:18:ff:0$VM_ID
 GDB_PORT=$((12340+VM_ID))
}
ensure_key() {
 need ssh-keygen
 mkdir -p "$LL_STATE/keys/public"
 if [[ ! -f $LL_STATE/keys/id_ed25519 ]]; then
   ssh-keygen -q -t ed25519 -N '' -f "$LL_STATE/keys/id_ed25519"
 fi
 cp "$LL_STATE/keys/id_ed25519.pub" "$LL_STATE/keys/public/authorized_keys"
}
