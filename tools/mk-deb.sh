#!/bin/bash
# Package a build as a FriendlyElec-style kernel deb for NanoPi6-family boards (CM3588, NanoPC-T6).
#   tools/mk-deb.sh KVER kernel.img|Image resource.img modules.tar.gz [debrev]
# Same install model as FriendlyElec's linux-image-* debs: postinst dd's kernel.img and
# resource.img onto the boot device's "kernel" and "resource" partitions (dtbo is left alone).
# Unlike theirs, it first saves the current partitions to /var/backups/cm3588-kernel/.
set -euo pipefail
KVER=$1 KIMG=$2 RES=$3 MODS=$4 REV=${5:-1}
TOP=$(cd "$(dirname "$0")/.." && pwd)
PKG=linux-image-$KVER
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
R=$W/root; mkdir -p "$R/DEBIAN" "$R/usr/lib/$PKG" "$R/lib/modules" "$R/usr/share/doc/$PKG"
if head -c4 "$KIMG" | grep -q KRNL; then cp "$KIMG" "$R/usr/lib/$PKG/kernel.img"
else "$TOP/kernel/scripts/mkkrnlimg" "$KIMG" "$R/usr/lib/$PKG/kernel.img" >/dev/null; fi
cp "$RES" "$R/usr/lib/$PKG/resource.img"
tar xzf "$MODS" -C "$R/lib/modules"
[ -d "$R/lib/modules/$KVER" ] || { echo "modules tar has no $KVER/"; exit 1; }
rm -f "$R/lib/modules/$KVER/"{build,source}
# depmod output is regenerated in postinst; ship without it so dpkg doesn't own it
rm -f "$R/lib/modules/$KVER/"modules.{alias,alias.bin,builtin.alias.bin,builtin.bin,dep,dep.bin,devname,softdep,symbols,symbols.bin}
cp "$TOP/README.md" "$R/usr/share/doc/$PKG/README.md" 2>/dev/null || true
SIZE=$(du -sk "$R" | cut -f1)
cat > "$R/DEBIAN/control" <<C
Package: $PKG
Source: cm3588-kernel
Version: $KVER-$REV
Architecture: arm64
Maintainer: Will Twomey <william.twomey@gmail.com>
Installed-Size: $SIZE
Section: kernel
Priority: optional
Depends: kmod
Homepage: https://github.com/williamtwomey/cm3588-kernel
Description: Linux kernel $KVER for FriendlyElec NanoPi6-family boards (CM3588)
 Community build, not from FriendlyElec. Installs like FriendlyElec's linux-image
 debs: flashes kernel.img and resource.img onto the boot device's kernel and
 resource partitions. The previous contents are saved to /var/backups/cm3588-kernel/.
 See https://github.com/williamtwomey/cm3588-kernel for what's in this build.
C
cat > "$R/DEBIAN/preinst" <<'P'
#!/bin/bash -e
[ "$1" = abort-upgrade ] && exit 0
board=$(tr -d '\0' < /proc/device-tree/board/machine 2>/dev/null || true)
if [ "${board,,}" != nanopi6 ]; then
    echo "Error: this kernel is for FriendlyElec NanoPi6-family boards (board/machine = NanoPi6), found '${board}'." >&2
    exit 1
fi
P
cat > "$R/DEBIAN/postinst" <<P
#!/bin/bash -e
[ "\$1" = configure ] || exit 0
KVER=$KVER
SRC=/usr/lib/linux-image-\$KVER
P
cat >> "$R/DEBIAN/postinst" <<'P'
rootdev() {
    local r=""
    for x in $(</proc/cmdline); do
        case "$x" in bootdev=*) r=${x#bootdev=}; break ;; root=*) [ -z "$r" ] && r=${x#root=} ;; esac
    done
    case "$r" in /dev/sd[a-g]*) echo "${r%[0-9]*}" ;; *) echo "${r%p*}" ;; esac
}
DEV=$(basename "$(rootdev)")
case "$DEV" in mmcblk[0-9]) PFX=${DEV}p ;; sd[a-g]) PFX=$DEV ;; *) echo "Error: can't tell the boot device from /proc/cmdline" >&2; exit 1 ;; esac
part() {
    for p in /sys/block/$DEV/$PFX*; do
        grep -q "^PARTNAME=$1$" "$p/uevent" 2>/dev/null && { echo "/dev/$(basename "$p")"; return; }
    done
}
K=$(part kernel); R=$(part resource)
if [ -z "$K" ] || [ -z "$R" ]; then
    echo "Error: no kernel/resource partitions on /dev/$DEV (not a FriendlyElec layout?)" >&2; exit 1
fi
depmod -a "$KVER"
B=/var/backups/cm3588-kernel/$(date +%Y%m%d-%H%M%S)-before-$KVER
mkdir -p "$B"
dd if="$K" of="$B/kernel.img" bs=1M status=none
dd if="$R" of="$B/resource.img" bs=1M status=none
echo "Saved the current kernel/resource partitions to $B"
echo "Flashing $KVER to $K and $R ..."
dd if="$SRC/kernel.img" of="$K" bs=4096 conv=fsync status=none
dd if="$SRC/resource.img" of="$R" bs=4096 conv=fsync status=none
sync
echo "Done. Reboot to run $KVER. To go back: dd the saved images back onto $K and $R,"
echo "or reinstall your previous linux-image deb."
P
cat > "$R/DEBIAN/prerm" <<P
#!/bin/bash -e
[ "\$1" = remove ] || exit 0
if [ "\$(uname -r)" = "$KVER" ]; then
    echo "You're running $KVER. Install another kernel deb (which reflashes the partitions) before removing this one." >&2
    exit 1
fi
P
chmod 755 "$R/DEBIAN/"{preinst,postinst,prerm}
(cd "$R" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | xargs -0 md5sum > DEBIAN/md5sums)
mkdir -p "$TOP/out/deb"
dpkg-deb --root-owner-group -Zxz -b "$R" "$TOP/out/deb/${PKG}_${KVER}-${REV}_arm64.deb" >/dev/null
echo "$TOP/out/deb/${PKG}_${KVER}-${REV}_arm64.deb"
