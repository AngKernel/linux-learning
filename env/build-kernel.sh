#!/usr/bin/env bash
# 用法：env/build-kernel.sh [--check|--configure]；无参数为增量编译。
source "$(dirname -- "$0")/common.sh"
[[ ${1:-} == --help ]] && { echo 'build-kernel.sh [--check|--configure]；BUILD_DIR / KERNEL_SRC / JOBS 可覆盖'; exit 0; }
[[ $# -le 1 && ${1:-} =~ ^(--check|--configure)?$ ]] || fail "未知参数"
check_source
for tool in make gcc ld flex bison python3 pahole bc pkg-config; do need "$tool"; done
pkg-config --exists libelf openssl || fail "缺少 libelf-dev / libssl-dev"
python3 - "$(pahole --version)" <<'PYCHECK'
import re,sys
v=tuple(map(int,re.search(r'(\d+)\.(\d+)',sys.argv[1]).groups()))
if v<(1,21): sys.exit('DWARF5 + BTF 需要 pahole >= 1.21')
PYCHECK
[[ ${1:-} != --check ]] || { echo '编译依赖检查通过（未编译）'; exit 0; }
init_state
mkdir -p "$BUILD_DIR"; BUILD_DIR=$(realpath "$BUILD_DIR")
case "$BUILD_DIR/" in "$KERNEL_SRC/"*|"$REPO/"*) fail 'BUILD_DIR 必须在源码树、学习仓库之外';; esac
exec 9>"$BUILD_DIR/.ll-build.lock"; flock -n 9 || fail '此 BUILD_DIR 已有编译进程'
if [[ ! -f $BUILD_DIR/.config ]]; then
 make -C "$KERNEL_SRC" O="$BUILD_DIR" ARCH=x86_64 defconfig
fi
# merge_config 在当前目录创建临时文件，必须切到外置输出目录。
(cd "$BUILD_DIR" && "$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -O "$BUILD_DIR" \
 "$BUILD_DIR/.config" "$KERNEL_SRC/kernel/configs/kvm_guest.config" "$ENV_DIR/kconfig/net-debug.config")
make -C "$KERNEL_SRC" O="$BUILD_DIR" ARCH=x86_64 olddefconfig
python3 - "$ENV_DIR/kconfig/net-debug.config" "$BUILD_DIR/.config" <<'PYCHECK'
import re,sys
actual=open(sys.argv[2]).read(); bad=[]
for line in open(sys.argv[1]):
 line=line.strip()
 if re.match(r'CONFIG_\w+=',line) and line not in actual.splitlines(): bad.append(line)
 if re.match(r'# CONFIG_\w+ is not set$',line):
  key=line.split()[1]
  if re.search(r'^'+key+r'=[ym]',actual,re.M): bad.append(line)
if bad: sys.exit('配置未生效（请修复依赖）：\n'+'\n'.join(bad))
PYCHECK
[[ ${1:-} != --configure ]] || exit 0
make -C "$KERNEL_SRC" O="$BUILD_DIR" ARCH=x86_64 -j"${JOBS:-$(nproc)}" bzImage modules scripts_gdb
make -C "$KERNEL_SRC" O="$BUILD_DIR" ARCH=x86_64 INSTALL_MOD_PATH="$BUILD_DIR/guest-modules" modules_install
python3 "$KERNEL_SRC/scripts/clang-tools/gen_compile_commands.py" --ar ar -d "$BUILD_DIR" -o "$BUILD_DIR/compile_commands.json"
echo "完成：$BUILD_DIR/arch/x86/boot/bzImage；clangd --compile-commands-dir=$BUILD_DIR"
