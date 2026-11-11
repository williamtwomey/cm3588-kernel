#!/bin/bash
# Build the CM3588 A/B boot SD card. Boot only: the rootfs stays on eMMC p8/p9.
#
#   sudo tools/mk-sdcard.sh /dev/sdX
#
# Layout (512-byte sectors). The low part matches FriendlyElec's eMMC layout so
# the eMMC's (non-A/B) SPL finds `uboot` on the card, either by name or by offset:
#   64       idbloader (DDR TPL + SPL), copied from the eMMC, so the card can also boot a blank-eMMC board
#   0x4000   uboot   4M   FriendlyElec U-Boot built with nanopi6_ab_defconfig
#   0x6000   misc    4M   A/B metadata (AvbABData @2048), see tools/cm3588-slot
#   0x8000   dtbo    4M   eMMC dtbo with every entry = entry 0 (eMMC root/data args)
#   0x10000  boot_a  128M Android boot image: 6.1.118 (stock FriendlyElec) Image + ramdisk + resource
#   ...      boot_b  128M Android boot image: our build
# Everything after boot_b is left unpartitioned for the later rootfs move.
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
DEV=${1:?usage: $0 /dev/sdX}
IN=$TOP/inputs
W=$TOP/out/sdcard
CMDLINE="root=/dev/mmcblk2p8 rw rootfstype=ext4 rootflags=discard data=/dev/mmcblk2p9"
SLOT_B_IMAGE=${SLOT_B_IMAGE:-$TOP/kernel/arch/arm64/boot/Image}
SLOT_B_RES=${SLOT_B_RES:-$TOP/out/resource.img}

[[ $(id -u) -eq 0 ]] || { echo "run as root"; exit 1; }
[[ -b $DEV ]] || { echo "$DEV is not a block device"; exit 1; }
b=$(basename "$DEV")
[[ $(cat /sys/block/$b/removable) == 1 || $(readlink -f /sys/block/$b) == */usb* ]] || { echo "$DEV isn't removable/USB; refusing"; exit 1; }
if lsblk -no MOUNTPOINT "$DEV" | grep -q .; then echo "$DEV has mounted partitions; unmount first"; exit 1; fi
for f in 6.1.118/Image 6.1.118/resource.img initrd.gz emmc/dtbo.img emmc/gpt-and-loader-first16M.img; do
  [[ -f $IN/$f ]] || { echo "missing $IN/$f"; exit 1; }
done
[[ -f $TOP/uboot/uboot.img ]] || { echo "missing uboot/uboot.img (build with ./make.sh nanopi6_ab)"; exit 1; }

mkdir -p "$W"
mkb() { python3 -I "$TOP/kernel/scripts/mkbootimg" --kernel "$1" --ramdisk "$IN/initrd.gz" \
          --second "$2" --cmdline "$CMDLINE" --os_version 12.0.0 --os_patch_level 2026-11 -o "$3"; }
mkb "$IN/6.1.118/Image" "$IN/6.1.118/resource.img" "$W/boot_a.img"
mkb "$SLOT_B_IMAGE" "$SLOT_B_RES" "$W/boot_b.img"
python3 -I "$TOP/tools/dtbo-single.py" "$IN/emmc/dtbo.img" "$W/dtbo.img"
truncate -s 0 "$W/misc.img"; truncate -s 4M "$W/misc.img"
python3 -I "$TOP/tools/cm3588-slot" --dev "$W/misc.img" init >/dev/null
dd if="$IN/emmc/gpt-and-loader-first16M.img" of="$W/idbloader.bin" bs=512 skip=64 count=$((0x4000 - 64)) status=none
ls -la "$W"

echo "== partitioning $DEV"
wipefs -a -q "$DEV"
sgdisk -Z "$DEV" >/dev/null
sgdisk -o \
  -n 1:$((0x4000)):$((0x6000 - 1))  -c 1:uboot \
  -n 2:$((0x6000)):$((0x8000 - 1))  -c 2:misc \
  -n 3:$((0x8000)):$((0xa000 - 1))  -c 3:dtbo \
  -n 4:$((0x10000)):+128M           -c 4:boot_a \
  -n 5:0:+128M                      -c 5:boot_b \
  "$DEV" >/dev/null
sgdisk -p "$DEV"
start() { sgdisk -i "$1" "$DEV" | awk '/First sector/{print $3}'; }

put() { dd if="$1" of="$DEV" bs=512 seek="$2" conv=fsync,notrunc status=none; }
put "$W/idbloader.bin" 64
put "$TOP/uboot/uboot.img" "$(start 1)"
put "$W/misc.img"   "$(start 2)"
put "$W/dtbo.img"   "$(start 3)"
put "$W/boot_a.img" "$(start 4)"
put "$W/boot_b.img" "$(start 5)"
sync

echo "== verify"
chk() { local n; n=$(stat -c%s "$1"); cmp -n "$n" "$1" <(dd if="$DEV" bs=512 skip="$2" count=$(( (n + 511) / 512 )) status=none) && echo "ok  $(basename "$1")"; }
chk "$W/idbloader.bin" 64
chk "$TOP/uboot/uboot.img" "$(start 1)"
chk "$W/misc.img" "$(start 2)"
chk "$W/dtbo.img" "$(start 3)"
chk "$W/boot_a.img" "$(start 4)"
chk "$W/boot_b.img" "$(start 5)"
echo "done: slot a = 6.1.118 (3 tries), slot b = $(strings "$SLOT_B_IMAGE" | grep -m1 -o 'Linux version [^ ]*') (unbootable until armed)"
