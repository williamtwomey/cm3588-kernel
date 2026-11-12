#!/bin/bash
# CM3588 kernel build.
#   ./build.sh                              FriendlyElec nanopi6-v6.1.y + fs fixes (kernel/)
#   KDIR=wt-rk2 KSUFFIX=-rk192 ./build.sh   Rockchip develop-6.1 + stable 6.1.192 + FriendlyElec board port
# Outputs to out/<suffix>/: Image, resource.img, modules-<KV>.tar.gz, SHA256SUMS
# (plus kernel.img for the FriendlyElec tree).
unset LOCALVERSION  # kbuild appends $LOCALVERSION to CONFIG_LOCALVERSION; use KSUFFIX
# neutral "Linux version ... (user@host)" string for published builds
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-builder} KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-cm3588-kernel}
set -euo pipefail
TOP=$(cd "$(dirname "$0")" && pwd)
K=$TOP/${KDIR:-kernel}; SUF=${KSUFFIX:--fsfix1}; OUT=$TOP/out/${SUF#-}
export ARCH=arm64; CC=aarch64-linux-gnu-gcc-14
MK="make -C $K ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- CC=$CC"
mkdir -p "$OUT"
cp "$TOP/config-6.1.118" "$K/.config"
"$K/scripts/config" --file "$K/.config" --set-str LOCALVERSION "$SUF" --enable IKCONFIG --enable IKCONFIG_PROC
# Rockchip's Broadcom wifi (bcmdhd) doesn't build against 6.1.192's cfg80211, and CM3588 has no wifi.
"$K/scripts/config" --file "$K/.config" --disable WL_ROCKCHIP
touch "$K/.scmversion"
$MK olddefconfig
if grep -q '^nanopi6-images:' "$K/arch/arm64/Makefile" 2>/dev/null; then
  $MK nanopi6-images -j"$(nproc)"
  cp "$K/kernel.img" "$K/resource.img" "$OUT/"
else
  # No FriendlyElec packing target: pack resource.img ourselves, same layout as
  # theirs (logo.bmp + logo_kernel.bmp + every nanopi6 DTB; U-Boot picks the DTB by board ID).
  $MK Image dtbs -j"$(nproc)"
  R=$OUT/resource-src; rm -rf "$R"; mkdir -p "$R"
  (cd "$R" && "$K/scripts/resource_tool" --unpack --image="$TOP/inputs/6.1.118/resource.img" >/dev/null)
  D=$R; [ -d "$R/out" ] && D=$R/out   # resource_tool unpacks into ./out
  rm -f "$D"/*.dtb
  cp "$K"/arch/arm64/boot/dts/rockchip/rk3588-nanopi6-rev*.dtb "$D/"
  # entry names must be bare (U-Boot looks up "logo.bmp", "rk3588-nanopi6-rev09.dtb")
  (cd "$D" && "$K/scripts/resource_tool" --pack --image="$OUT/resource.img" logo.bmp logo_kernel.bmp rk3588-nanopi6-rev*.dtb >/dev/null)
  "$K/scripts/resource_tool" --print --image="$OUT/resource.img" | grep -E "name|path" | head -40 > "$OUT/resource.list" || true
fi
cp "$K/arch/arm64/boot/Image" "$OUT/Image"
KV=$($MK -s kernelrelease)
rm -rf "$OUT/modules"; mkdir -p "$OUT/modules"
$MK modules -j"$(nproc)"
$MK INSTALL_MOD_PATH="$OUT/modules" INSTALL_MOD_STRIP=1 modules_install
$MK KCFLAGS="-fmacro-prefix-map=$TOP/=" M="$TOP/r8125/src" modules -j"$(nproc)" 2>/dev/null || $MK KCFLAGS="-fmacro-prefix-map=$TOP/=" M="$TOP/r8125" modules -j"$(nproc)"
mkdir -p "$OUT/modules/lib/modules/$KV/extra"
find "$TOP/r8125" -name r8125.ko -exec cp {} "$OUT/modules/lib/modules/$KV/extra/" \;
aarch64-linux-gnu-strip --strip-debug "$OUT/modules/lib/modules/$KV/extra/"*.ko
rm -f "$OUT/modules/lib/modules/$KV/"{build,source}
depmod -a -b "$OUT/modules" "$KV"
tar czf "$OUT/modules-$KV.tar.gz" -C "$OUT/modules/lib/modules" "$KV"
(cd "$OUT" && sha256sum Image resource.img "modules-$KV.tar.gz" > SHA256SUMS)
echo "BUILT $KV -> $OUT"
