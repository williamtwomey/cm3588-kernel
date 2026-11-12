# cm3588-kernel

Kernel builds for the FriendlyElec CM3588 (NAS kit), plus the fix for the XFS hang that keeps a lot of people stuck on 6.1.118.

If you run Docker on an XFS volume and FriendlyElec's 6.1.141 kernel left your containers stuck in D state, this is that bug. It's a bad merge in the Android Common Kernel that FriendlyElec's tree inherits, and the fix is one line.

## The XFS hang

In `android14-6.1-lts`, `xfs_buffered_write_iomap_begin()` unlocks the inode ILOCK twice on the COW path (`found_cow:`). An ACK revert from 2024 restored an early `xfs_iunlock()`, and the 6.1.138 merge then added upstream's per-return unlocks next to it. The second unlock corrupts the rwsem, and the next `xfs_ilock()` on that inode sleeps forever.

The COW path only runs on reflinked extents. overlayfs copy-up on XFS with `reflink=1` (the mkfs default) creates them, so Docker/containerd overlay2 on XFS hangs on the first chown or truncate of a copied-up file. 6.1.118 predates the merge, which is why rolling back works.

- Full write-up: [upstream-report-ack-xfs-double-unlock.md](upstream-report-ack-xfs-double-unlock.md)
- Fix: [patches/0001-xfs-fix-double-ILOCK-unlock-in-xfs_buffered_write_io.patch](patches/0001-xfs-fix-double-ILOCK-unlock-in-xfs_buffered_write_io.patch)
- Reproducer: [tools/xfs-overlay-repro.sh](tools/xfs-overlay-repro.sh). It uses a tmpfs-backed loop device, so it doesn't touch your disks. On stock 6.1.141 it wedges in round 1, and it passes 20/20 rounds with the fix. Run it on a box you can reboot, since a failed run leaves hung tasks behind.
- Traces: [evidence/](evidence/)
- FriendlyElec PR: https://github.com/friendlyarm/kernel-rockchip/pull/14

## Builds

Both are on the [releases page](https://github.com/williamtwomey/cm3588-kernel/releases) as debs.

| Package | What it is | Status |
|---|---|---|
| `linux-image-6.1.141-fsfix2` | FriendlyElec `nanopi6-v6.1.y` (6.1.141) + the double-unlock fix + 71 stable fs/xfs, overlayfs and iomap fixes from up to 6.1.192 | Ran a day with 39 containers on XFS/overlay2, no hangs. Recommended. |
| `linux-image-6.1.192-rk192` | Rockchip `develop-6.1` (6.1.172) merged with stable v6.1.192, plus FriendlyElec's board support ported over (DTS, RKNPU 0.9.8, PCIe/combphy/pwm-fan bits). No ACK code, so the bug never existed here. | Experimental. Boots and runs everything on my board (NVMe RAID, 2.5G NIC, NPU, MPP/RGA for Immich), but it's new. On one of two boots the RTL8125's PCIe link didn't train, and I haven't root-caused it yet. |

Both are built with gcc 14 from FriendlyElec's 6.1.118 config (`olddefconfig`) and include FriendlyElec's out-of-tree `r8125` driver. rk192 has Broadcom wifi (`bcmdhd`) disabled, since it doesn't build against 6.1.192's cfg80211 and the CM3588 has no wifi.

### Installing

These install the same way FriendlyElec's own `linux-image-*` debs do. postinst writes `kernel.img` and `resource.img` onto the `kernel` and `resource` partitions of the device you booted from (eMMC or SD), and leaves dtbo alone. Unlike FriendlyElec's, it saves the current partitions to `/var/backups/cm3588-kernel/` first.

```
sudo dpkg -i linux-image-6.1.141-fsfix2_6.1.141-fsfix2-1_arm64.deb
sudo reboot
```

To go back, reinstall your previous kernel deb, or `dd` the saved `kernel.img` and `resource.img` back onto those partitions.

**Have a way back before you try this.** If a kernel doesn't boot, you need a FriendlyElec SD card image or MaskROM (`rkdeveloptool`) to recover. If you want to test without touching the eMMC, see the A/B SD card below.

Tested on a CM3588 NAS kit only. The debs refuse to install on anything that doesn't report `NanoPi6` in `/proc/device-tree/board/machine`. That covers the whole NanoPi6 family, but I haven't tried the others.

No headers package yet, so out-of-tree DKMS modules won't build against these.

## A/B SD card (optional)

`tools/mk-sdcard.sh` builds a microSD card that boots kernels from two slots with U-Boot's Android A/B logic. A new kernel boots once on trial and falls back to the known-good slot if it doesn't get marked good. The eMMC isn't touched, and pulling the card boots the eMMC as before. `tools/cm3588-slot` manages the slots (`status`, `mark-good`, `arm a --boots 1`).

It's how both builds here were tested. The gotchas I hit are in the comments of `mk-sdcard.sh` and `cm3588-slot`. The main one: U-Boot fails to read a 16M `second` stage from SD, so resource lives in its own per-slot partitions.

## Building

```
./build.sh                                # FriendlyElec tree in kernel/ (KSUFFIX=-fsfix2 for that suffix)
KDIR=wt-rk2 KSUFFIX=-rk192 ./build.sh     # Rockchip + stable tree
tools/mk-deb.sh <kver> <kernel.img|Image> <resource.img> <modules.tar.gz>
```

`build.sh` expects the kernel trees and FriendlyElec's `r8125` source checked out next to it, plus a 6.1.118 `resource.img` under `inputs/` (for the logos). How to rebuild the rk192 tree from Rockchip + stable is in [patches/rk192/README.md](patches/rk192/README.md).

## License

Kernel code and patches are GPL-2.0, like the kernel. The scripts in `tools/` are GPL-2.0 too.
