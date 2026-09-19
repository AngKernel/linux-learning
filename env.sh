# source env.sh [版本]     例：source env.sh 5.15
# 不带参数则沿用上次的 $KVER，再没有就用 6.18

_le_self="${BASH_SOURCE[0]:-$0}"
export LEARN_ROOT="$(cd "$(dirname "$_le_self")" && pwd)"
export KSRC_ROOT="${KSRC_ROOT:-$HOME/src}"
export KVER="${1:-${KVER:-6.18}}"
export KDIR="$KSRC_ROOT/linux-$KVER"

if [ -d "$KDIR" ]; then
    printf 'KVER=%s\nKDIR=%s\n' "$KVER" "$KDIR"
    if [ -f "$KDIR/Makefile" ]; then
        printf 'tag =%s\n' "$(git -C "$KDIR" describe --tags 2>/dev/null || echo '?')"
    fi
else
    printf '[!] %s 不存在。新增一个版本：./scripts/newver.sh v%s\n' "$KDIR" "$KVER"
fi
unset _le_self
