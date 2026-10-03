#!/usr/bin/env bash
# 用法：env/down.sh [1|2]；先 guest poweroff，必要时经本 VM QMP 退出；不删除磁盘。
source "$(dirname -- "$0")/common.sh"
[[ ${1:-} == --help ]] && { echo 'down.sh [1|2]；停止后用 sudo topology.sh down 拆桥'; exit 0; }
init_state; vm_vars "${1:-1}"
[[ -S $VM_DIR/qmp.sock ]] || { echo '没有活动 QMP socket'; exit 0; }
"$ENV_DIR/ssh.sh" "$VM_ID" sudo poweroff >/dev/null 2>&1 || true
for ((i=0;i<10;i++)); do [[ -S $VM_DIR/qmp.sock ]] || break; sleep 1; done
if [[ -S $VM_DIR/qmp.sock ]]; then
 python3 - "$VM_DIR/qmp.sock" <<'PYQMP'
import json,socket,sys
s=socket.socket(socket.AF_UNIX); s.settimeout(5)
try: s.connect(sys.argv[1])
except ConnectionRefusedError: sys.exit(0) # 仅清理本实例的过期 socket
f=s.makefile('rwb'); json.loads(f.readline())
for cmd in ('qmp_capabilities','quit'):
 f.write((json.dumps({'execute':cmd})+'\n').encode()); f.flush()
 while True:
  raw=f.readline()
  if not raw: break
  r=json.loads(raw)
  if 'error' in r: sys.exit(str(r))
  if 'return' in r: break
PYQMP
fi
rm -f "$VM_DIR/qmp.sock"
echo "VM$VM_ID 已停止，持久磁盘和日志保留。"
