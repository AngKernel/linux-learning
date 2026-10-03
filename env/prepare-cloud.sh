#!/usr/bin/env bash
# 用法：env/prepare-cloud.sh [1|2]；首次下载 Debian cloud image，校验 SHA512，再建立 overlay/seed。
source "$(dirname -- "$0")/common.sh"
[[ ${1:-} == --help ]] && { echo 'prepare-cloud.sh [1|2]；BASE_IMAGE 可指定已校验的本地 qcow2'; exit 0; }
init_state; vm_vars "${1:-1}"; ensure_key
for tool in qemu-img cloud-localds curl python3; do need "$tool"; done
mkdir -p "$VM_DIR" "$LL_STATE/images"
[[ ! -e $VM_DIR/qmp.sock ]] || fail '请先停机再准备 cloud image'
if [[ -z ${BASE_IMAGE:-} ]]; then
 # 可设置固定版本目录，避免 latest 变化；默认目录和镜像可覆盖。
 url=${CLOUD_URL:-https://cloud.debian.org/images/cloud/trixie/latest}
 name=${CLOUD_IMAGE_NAME:-debian-13-genericcloud-amd64.qcow2}
 BASE_IMAGE=$LL_STATE/images/$name
 if [[ ! -f $BASE_IMAGE ]]; then
  tmp=$(mktemp -d "$LL_STATE/images/download.XXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT
  curl -fL --retry 2 "$url/$name" -o "$tmp/$name"
  curl -fL --retry 2 "$url/SHA512SUMS" -o "$tmp/SHA512SUMS"
  (cd "$tmp" && python3 - "$name" <<'PYCHECK'
import hashlib,sys
from pathlib import Path
name=sys.argv[1]; sums={line.split()[-1].lstrip('*'):line.split()[0] for line in Path('SHA512SUMS').read_text().splitlines() if line.strip()}
h=hashlib.sha512()
with open(name,'rb') as f:
 for block in iter(lambda:f.read(1048576),b''): h.update(block)
if sums.get(name)!=h.hexdigest(): sys.exit('镜像 SHA512 不匹配；latest 可能已轮换，请重新执行')
PYCHECK
  )
  mv "$tmp/$name" "$BASE_IMAGE"
 fi
fi
BASE_IMAGE=$(realpath "$BASE_IMAGE"); [[ -f $BASE_IMAGE ]] || fail 'BASE_IMAGE 不存在'
if [[ ! -f $VM_DIR/root.qcow2 ]]; then
 qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$VM_DIR/root.qcow2"
 qemu-img resize "$VM_DIR/root.qcow2" "${DISK_SIZE:-16G}"
fi
key=$(cat "$LL_STATE/keys/public/authorized_keys")
cat > "$VM_DIR/user-data" <<EOF
#cloud-config
hostname: ll-vm$VM_ID
users:
  - name: learner
    groups: [sudo]
    shell: /bin/bash
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    ssh_authorized_keys:
      - $key
ssh_pwauth: false
package_update: true
packages: [bpftrace, bpftool, linux-perf, iperf3, tcpdump, iproute2, ethtool, openssh-server]
mounts:
  - [llrepo, /work, 9p, 'trans=virtio,version=9p2000.L,msize=262144,rw,nofail', '0', '0']
write_files:
  - path: /etc/systemd/system/ll-iperf.service
    content: |
      [Unit]
      Description=linux-learning iperf3 server
      After=network-online.target
      [Service]
      ExecStart=/usr/bin/iperf3 -s
      Restart=on-failure
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [mkdir, -p, /work]
  - [mount, -a]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, ll-iperf.service]
EOF
cat > "$VM_DIR/meta-data" <<EOF
instance-id: ll-vm$VM_ID
local-hostname: ll-vm$VM_ID
EOF
cat > "$VM_DIR/network-config" <<EOF
version: 2
ethernets:
  lab:
    match: {macaddress: '$MAC'}
    set-name: lab0
    addresses: [$VM_IP/24]
  uplink:
    match: {macaddress: '$UPLINK_MAC'}
    set-name: wan0
    dhcp4: true
EOF
cloud-localds --network-config="$VM_DIR/network-config" "$VM_DIR/seed.img" "$VM_DIR/user-data" "$VM_DIR/meta-data"
echo "已准备 $VM_DIR；cloud-init 只在首次引导时配置，修改 seed 不会重置持久盘。"
