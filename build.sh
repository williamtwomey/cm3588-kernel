#!/bin/bash
# CM3588 kernel build: FriendlyElec nanopi6-v6.1.y + cherry-picked stable fixes.
set -euo pipefail
TOP=$(cd "$(dirname "$0")" && pwd)
K=$TOP/kernel; OUT=$TOP/out
export ARCH=arm64; CC=aarch64-linux-gnu-gcc-14
MK="make -C $K ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- CC=$CC"
cp "$TOP/config-6.1.118" "$K/.config"
"$K/scripts/config" --file "$K/.config" --set-str LOCALVERSION "${LOCALVERSION:--fsfix1}" --enable IKCONFIG --enable IKCONFIG_PROC
touch "$K/.scmversion"
$MK olddefconfig
$MK nanopi6-images -j"$(nproc)"
KV=$($MK -s kernelrelease)
rm -rf "$OUT/modules"; mkdir -p "$OUT/modules"
$MK modules -j"$(nproc)"
$MK INSTALL_MOD_PATH="$OUT/modules" INSTALL_MOD_STRIP=1 modules_install
$MK M="$TOP/r8125/src" modules -j"$(nproc)" 2>/dev/null || $MK M="$TOP/r8125" modules -j"$(nproc)"
mkdir -p "$OUT/modules/lib/modules/$KV/extra"
find "$TOP/r8125" -name r8125.ko -exec cp {} "$OUT/modules/lib/modules/$KV/extra/" \;
aarch64-linux-gnu-strip --strip-debug "$OUT/modules/lib/modules/$KV/extra/"*.ko
rm -f "$OUT/modules/lib/modules/$KV/"{build,source}
depmod -a -b "$OUT/modules" "$KV"
cp "$K/kernel.img" "$K/resource.img" "$OUT/"
tar czf "$OUT/modules-$KV.tar.gz" -C "$OUT/modules/lib/modules" "$KV"
(cd "$OUT" && sha256sum kernel.img resource.img "modules-$KV.tar.gz" > SHA256SUMS)
echo "BUILT $KV"
