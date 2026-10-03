#!/usr/bin/env bash
# 用法：env/up.sh quick|cloud [1|2]；ACCEL=kvm 默认，显式 ACCEL=tcg 为慢速替代。
source "$(dirname -- "$0")/common.sh"
[[ ${1:-} == --help ]] && { echo 'up.sh quick|cloud [1|2]；PAUSE=1 启动后等待 GDB，ACCEL=tcg 可不用 KVM'; exit 0; }
mode=${1:-quick}; [[ $mode == quick || $mode == cloud ]] || fail '模式必须为 quick/cloud'
init_state; vm_vars "${2:-1}"; check_source; need qemu-system-x86_64; ensure_key
[[ -f $BUILD_DIR/arch/x86/boot/bzImage ]] || fail '请先 build-kernel.sh'
[[ -c /dev/net/tun && -e /sys/class/net/$TAP ]] || fail '先在宿主执行 sudo env/topology.sh up $(id -u)'
[[ $(cat "/sys/class/net/$TAP/ifalias") == linux-learning:P3 ]] || fail 'TAP 不属于实验'
accel=${ACCEL:-kvm}; [[ $accel == kvm || $accel == tcg ]] || fail 'ACCEL=kvm 或 tcg'
if [[ $accel == kvm ]]; then [[ -r /dev/kvm && -w /dev/kvm ]] || fail 'KVM 不可用；检查设备/组权限，或显式 ACCEL=tcg'; fi
mkdir -p "$VM_DIR"
[[ ! -e $VM_DIR/qmp.sock ]] || fail '已有 QMP socket；先 down.sh，勿并发启动同一 VM'
rm -f "$VM_DIR/known_hosts"
qargs=(-name "ll-vm$VM_ID" -qmp "unix:$VM_DIR/qmp.sock,server=on,wait=off"
 -netdev "tap,id=lab,ifname=$TAP,script=no,downscript=no"
 -device "virtio-net-pci,netdev=lab,mac=$MAC"
 -gdb "tcp:127.0.0.1:$GDB_PORT")
[[ ${PAUSE:-0} != 1 ]] || qargs+=(-S)
if [[ $mode == quick ]]; then
 need virtme-run
 for tool in bpftrace bpftool perf iperf3 tcpdump ss ethtool sshd; do need "$tool"; done
 # 使用 virtme-ng 附带的 virtme-run；强制 9p 避免额外 virtiofsd 依赖。
 # --qemu-opts 必须最后；关闭 microvm 以使用 PCI virtio 网卡。
 cmd=(virtme-run --kdir "$BUILD_DIR" --mods=none --force-9p --disable-microvm
  --memory "${MEMORY:-4096M}" --cpus "${CPUS:-2}" --user root --empty-passwords
  --rwdir "/work=$REPO" --rodir "/kernel-build=$BUILD_DIR" --rodir "/run/ll-host=$LL_STATE/keys/public"
  --kopt nokaslr --kopt net.ifnames=0
  --script-sh "/work/env/guest-quick.sh $VM_ID")
 [[ $accel != tcg ]] || cmd+=(--disable-kvm)
 cmd+=(--qemu-opts "${qargs[@]}")
else
 [[ -f $VM_DIR/root.qcow2 && -f $VM_DIR/seed.img ]] || fail '先执行 prepare-cloud.sh'
 cpu=max; [[ $accel != kvm ]] || cpu=host
 cmd=(qemu-system-x86_64 -accel "$accel" -cpu "$cpu" -m "${MEMORY:-4096M}" -smp "${CPUS:-2}"
  -display none -serial stdio -monitor none -no-reboot
  -kernel "$BUILD_DIR/arch/x86/boot/bzImage"
  -append "root=${ROOT_DEVICE:-/dev/vda1} rw rootwait console=ttyS0 nokaslr"
  -drive "file=$VM_DIR/root.qcow2,if=virtio,format=qcow2"
  -drive "file=$VM_DIR/seed.img,if=virtio,format=raw,readonly=on"
  -virtfs "local,path=$REPO,mount_tag=llrepo,security_model=mapped-xattr,id=llrepo"
  -virtfs "local,path=$BUILD_DIR,mount_tag=llbuild,security_model=none,readonly=on,id=llbuild"
  -netdev user,id=wan -device "virtio-net-pci,netdev=wan,mac=$UPLINK_MAC"
  "${qargs[@]}")
fi
printf '%q ' "${cmd[@]}" > "$VM_DIR/command.txt"; printf '\n' >> "$VM_DIR/command.txt"
printf '%s\n' "$mode" > "$VM_DIR/mode"
nohup "${cmd[@]}" > "$VM_DIR/console.log" 2>&1 < /dev/null &
echo $! > "$VM_DIR/launcher.pid"
sleep 1
kill -0 "$(cat "$VM_DIR/launcher.pid")" 2>/dev/null || { tail -30 "$VM_DIR/console.log" >&2; fail '启动失败'; }
echo "已启动 VM$VM_ID；$VM_IP；控制台 $VM_DIR/console.log；GDB 127.0.0.1:$GDB_PORT"
