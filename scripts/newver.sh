#!/usr/bin/env bash
# 增加一个内核版本的 worktree
#   ./scripts/newver.sh v6.6
#   ./scripts/newver.sh v6.12.110
#   ./scripts/newver.sh linux-6.12.y 6.12-tip    # 跟 stable 分支而不是 tag
set -euo pipefail

ref="${1:?用法: newver.sh <tag或分支> [目录后缀]}"
suffix="${2:-${ref#v}}"
KSRC_ROOT="${KSRC_ROOT:-/home/chen/code/linux-lab/src}"
HUB="$KSRC_ROOT/linux"
dest="$KSRC_ROOT/linux-$suffix"

[ -d "$HUB/.git" ] || { echo "找不到主克隆 $HUB"; exit 1; }
[ -d "$dest" ] && { echo "$dest 已存在"; exit 1; }

git -C "$HUB" fetch --tags origin
git -C "$HUB" worktree add -b "study/$suffix" "$dest" "$ref"
echo "OK -> $dest  (分支 study/$suffix)"
echo "下一步: ./scripts/kbuild.sh $suffix"
