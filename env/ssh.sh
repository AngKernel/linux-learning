#!/usr/bin/env bash
# 用法：env/ssh.sh [1|2] [远程命令 ...]；仅使用本实验的 key/known_hosts。
source "$(dirname -- "$0")/common.sh"
[[ ${1:-} == --help ]] && { echo 'ssh.sh [1|2] [远程命令]'; exit 0; }
init_state; vm_vars "${1:-1}"; [[ $# == 0 ]] || shift
[[ -f $VM_DIR/mode ]] || fail '此 VM 尚未启动'
user=learner; [[ $(cat "$VM_DIR/mode") != quick ]] || user=root
exec ssh -i "$LL_STATE/keys/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
 -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$VM_DIR/known_hosts" "$user@$VM_IP" "$@"
