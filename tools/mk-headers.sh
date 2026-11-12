#!/bin/bash
# Build linux-headers-<kver> deb for a tree built by build.sh.
#   tools/mk-headers.sh KDIR KVER [debrev]
# Collects the external-module build tree the way the kernel's builddeb does, rebuilds its
# host programs natively on an arm64 box ($ARM_HOST, default CM3588) with
# tools/rebuild-hostprogs.sh, and packages it. The arm64 box's glibc sets the floor for
# the host tools (CM3588 is Ubuntu 22.04, glibc 2.35).
set -euo pipefail
KDIR=$1 KVER=$2 REV=${3:-1}
ARM_HOST=${ARM_HOST:-root@192.168.88.36}
TOP=$(cd "$(dirname "$0")/.." && pwd)
K=$TOP/$KDIR
PKG=linux-headers-$KVER
[ "$(make -s -C "$K" ARCH=arm64 kernelrelease)" = "$KVER" ] || { echo "$K isn't built as $KVER"; exit 1; }
W=$TOP/out/hdr-$KVER; rm -rf "$W"; mkdir -p "$W/root/DEBIAN"
D=$W/root/usr/src/$PKG; mkdir -p "$D"
( cd "$K"
  { find . arch/arm64 -maxdepth 1 -name 'Makefile*'
    find include scripts -type f -o -type l
    find arch/arm64 -name Kbuild.platforms -o -name Platform
    find $(find arch/arm64 -name include -o -name scripts -type d) -type f
  } > "$W/src"
  find arch/arm64/include Module.symvers include scripts -type f > "$W/obj"
  tar -cf - -T "$W/src" | tar -xf - -C "$D"
  tar -cf - -T "$W/obj" | tar -xf - -C "$D"
  cp .config "$D/.config" )
# The kernel is built with gcc 14 and its flags assume gcc >= 12 (e.g. -ftrivial-auto-var-init);
# Ubuntu 22.04's default gcc is 11. Default CC to the newest gcc-14/13/12 present, so plain
# `make` and DKMS work; CC=... on the command line still overrides.
grep -q '^CC		= $(CROSS_COMPILE)gcc$' "$D/Makefile"
sed -i 's|^CC\t\t= $(CROSS_COMPILE)gcc$|# cm3588-kernel: newest of gcc-14/13/12 (the kernel was built with gcc 14; gcc 11 rejects its flags)\nCC\t\t= $(CROSS_COMPILE)$(or $(firstword $(foreach c,gcc-14 gcc-13 gcc-12,$(if $(shell command -v $(CROSS_COMPILE)$(c) 2>/dev/null),$(c)))),gcc)|' "$D/Makefile"
mkdir -p "$W/root/lib/modules/$KVER"; ln -s "/usr/src/$PKG" "$W/root/lib/modules/$KVER/build"
# host programs: rebuild natively on arm64
R=/var/tmp/cm3588-hdr-$KVER
ssh "$ARM_HOST" "rm -rf $R && mkdir -p $R"
tar -C "$D" -czf - . | ssh "$ARM_HOST" "tar -C $R -xzf -"
scp -q "$TOP/tools/rebuild-hostprogs.sh" "$ARM_HOST:$R.rebuild.sh"
ssh "$ARM_HOST" "bash $R.rebuild.sh $R"
rm -rf "$D"; mkdir -p "$D"
ssh "$ARM_HOST" "tar -C $R -czf - . && rm -rf $R $R.rebuild.sh" | tar -C "$D" -xzf -
SIZE=$(du -sk "$W/root" | cut -f1)
cat > "$W/root/DEBIAN/control" <<C
Package: $PKG
Source: cm3588-kernel
Version: $KVER-$REV
Architecture: arm64
Maintainer: Will Twomey <william.twomey@gmail.com>
Installed-Size: $SIZE
Section: kernel
Priority: optional
Depends: gcc-14 | gcc-13 | gcc-12, make, libc6-dev
Suggests: linux-image-$KVER
Homepage: https://github.com/williamtwomey/cm3588-kernel
Description: Linux kernel headers for $KVER (CM3588 / NanoPi6 family)
 Build tree for external modules (DKMS etc.) against linux-image-$KVER.
 Host tools are built for arm64 (glibc 2.35+). Modules are compiled with the
 newest of gcc-14/13/12 found, since the kernel was built with gcc 14.
C
(cd "$W/root" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | xargs -0 md5sum > DEBIAN/md5sums)
mkdir -p "$TOP/out/deb"
dpkg-deb --root-owner-group -Zxz -b "$W/root" "$TOP/out/deb/${PKG}_${KVER}-${REV}_arm64.deb" >/dev/null
rm -rf "$W"
echo "$TOP/out/deb/${PKG}_${KVER}-${REV}_arm64.deb"
