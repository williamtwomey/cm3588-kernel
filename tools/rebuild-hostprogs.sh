#!/bin/bash
# Rebuild a cross-built headers tree's host programs (fixdep, modpost, genksyms, conf...)
# natively, so external modules build on the board itself. Run ON the arm64 target (or a
# matching arm64 userland): tools/rebuild-hostprogs.sh /path/to/linux-headers-<kver>
# Replays each object's recorded kbuild command (.<name>.cmd) with the native gcc,
# objects first, then links. Tools that can't be rebuilt from a headers tree are removed.
set -euo pipefail
cd "$1"
mapfile -t BIN < <(find scripts -type f | while read -r f; do file -b "$f" | grep -q '^ELF' && file -b "$f" | grep -qv 'ARM aarch64' && echo "$f"; done)
replay() {
    local f=$1 cmd=$(dirname "$1")/.$(basename "$1").cmd
    [ -f "$cmd" ] || return 1
    local c; c=$(sed -n 's/^\(saved\)\?cmd_[^ ]* := //p' "$cmd" | head -1)
    [ -n "$c" ] || return 1
    eval "$c"
}
fail=()
for pass in obj exe; do
    for f in "${BIN[@]}"; do
        case "$f" in *.o) [ $pass = obj ] || continue ;; *) [ $pass = exe ] || continue ;; esac
        if ! replay "$f" 2>/dev/null; then fail+=("$f"); fi
    done
done
need=(scripts/basic/fixdep scripts/mod/modpost scripts/genksyms/genksyms scripts/kconfig/conf scripts/mod/mk_elfconfig)
for n in "${need[@]}"; do
    [ -f "$n" ] && file -b "$n" | grep -q 'ARM aarch64' || { echo "FAILED to rebuild required $n" >&2; exit 1; }
done
for f in "${fail[@]}"; do
    if [ -f "$f" ] && ! file -b "$f" | grep -q 'ARM aarch64'; then echo "removing (couldn't rebuild): $f"; rm -f "$f"; fi
done
find scripts -name '*.o' -delete
find scripts -name '.*.cmd' -delete
find scripts -name '.*.d' -delete
left=$(find scripts -type f -exec file {} + | grep ELF | grep -vc 'ARM aarch64' || true)
echo "host programs rebuilt; foreign ELF left: $left"
