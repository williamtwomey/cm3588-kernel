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

They're all on the [releases page](https://github.com/williamtwomey/cm3588-kernel/releases) as debs.

| Package | What it is | Status |
|---|---|---|
| `linux-image-6.1.141-fsfix2` | FriendlyElec `nanopi6-v6.1.y` (6.1.141) + the double-unlock fix + 71 stable fs/xfs, overlayfs and iomap fixes from up to 6.1.192 | Ran a day with 39 containers on XFS/overlay2, no hangs. Recommended. |
| `6.1.193-rk193` | rk192 merged with stable v6.1.193 (rk192.1's two fixes are upstream in .193). See [patches/rk193](patches/rk193/README.md). | Experimental. Boots and runs everything on my board (same checks as rk192.1, both repros pass), but uptime is short so far; long-term testing is ongoing. Replaces rk192.1. [Release 2026.11.23](https://github.com/williamtwomey/cm3588-kernel/releases/tag/2026.11.23). |
| `linux-image-6.1.192-rk192.1` | rk192 plus two stable-queue fixes for NULL folio dereferences that 6.1.192 itself shipped (ext4 mballoc, ntfs3). See below. | Experimental, same as rk192. Replaces rk192; don't run rk192. |
| `linux-image-6.1.192-rk192` | Rockchip `develop-6.1` (6.1.172) merged with stable v6.1.192, plus FriendlyElec's board support ported over (DTS, RKNPU 0.9.8, PCIe/combphy/pwm-fan bits). No ACK code, so the bug never existed here. | **Superseded by rk192.1.** Oopses in ext4 under memory pressure and wedges the box (below). Otherwise it boots and runs everything on my board (NVMe RAID, 2.5G NIC, NPU, MPP/RGA for Immich). On one of two boots the RTL8125's PCIe link didn't train, and I haven't root-caused it yet. |

Both are built with gcc 14 from FriendlyElec's 6.1.118 config (`olddefconfig`) and include FriendlyElec's out-of-tree `r8125` driver. rk192 has Broadcom wifi (`bcmdhd`) disabled, since it doesn't build against 6.1.192's cfg80211 and the CM3588 has no wifi.

### rk192: ext4 oops in 6.1.192 (fixed in rk192.1)

Stable 6.1.192 backported ext4's mballoc conversion to folios (`d34e4fd4e73f`, `862483175d3d`) and kept upstream's `IS_ERR()` checks. In 6.1, `__filemap_get_folio()` returns NULL, not an `ERR_PTR` (that change came in 6.4), so the checks never fire. Once a block group's buddy or bitmap page has been evicted from the page cache, the next allocation from that group dereferences NULL:

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000000
Workqueue: writeback wb_workfn (flush-179:0)
pc : ext4_mb_load_buddy_gfp+0xa8/0x428
 ext4_mb_find_by_goal <- ext4_mb_regular_allocator <- ext4_mb_new_blocks
 <- ext4_ext_map_blocks <- ext4_map_blocks <- ext4_writepages <- wb_workfn
```

This affects any 6.1.192 kernel, not just this tree. On my board it hit the eMMC rootfs (ext4) a few times a day. The oops kills the writeback worker without panicking, so the box locks up rather than rebooting, and nothing makes it to the journal. pstore (`/var/lib/systemd/pstore/`) had the trace.

rk192.1 adds the two fixes queued for 6.1.193, `ext4: fix NULL folio dereference in mballoc` and `ntfs3: fix NULL folio dereference in ntfs_lock_new_page()` (both by Elliot Berman), as [patches/rk192/0015](patches/rk192/0015-ext4-fix-NULL-folio-dereference-in-mballoc.patch) and [0016](patches/rk192/0016-ntfs3-fix-NULL-folio-dereference.patch). I checked the rest of the tree for `IS_ERR()` after a `__filemap_get_folio()` and those were the only two. fsfix2 is FriendlyElec's 6.1.141 with only fs/xfs, overlayfs and iomap picks, so it doesn't have the mballoc conversion and isn't affected.

Reproducer: [tools/ext4-mballoc-repro.sh](tools/ext4-mballoc-repro.sh), on a throwaway ext4 loop image. It writes, drops caches, and writes again. rk192.1 passes 20/20 rounds. ftrace shows it reaches `ext4_mb_init_cache` from `dd`, which only happens after the fast-path folio lookup misses, i.e. the case that oopses on rk192. I haven't run it on rk192 itself, since that would wedge my server.

### Installing

These install the same way FriendlyElec's own `linux-image-*` debs do. postinst writes `kernel.img` and `resource.img` onto the `kernel` and `resource` partitions of the device you booted from (eMMC or SD), and leaves dtbo alone. Unlike FriendlyElec's, it saves the current partitions to `/var/backups/cm3588-kernel/` first.

```
sudo dpkg -i linux-image-6.1.141-fsfix2_6.1.141-fsfix2-1_arm64.deb
sudo reboot
```

To go back, reinstall your previous kernel deb, or `dd` the saved `kernel.img` and `resource.img` back onto those partitions.

**Have a way back before you try this.** If a kernel doesn't boot, you need a FriendlyElec SD card image or MaskROM (`rkdeveloptool`) to recover. If you want to test without touching the eMMC, see the A/B SD card below.

Tested on a CM3588 NAS kit only. The debs refuse to install on anything that doesn't report `NanoPi6` in `/proc/device-tree/board/machine`. That covers the whole NanoPi6 family, but I haven't tried the others.

### Headers

`linux-headers-<kver>` debs are on the release too, for building out-of-tree modules (DKMS and the like). They install to `/usr/src/linux-headers-<kver>` and add the `/lib/modules/<kver>/build` link. You don't need the matching kernel running to build against them.

The kernels are built with gcc 14, and some of the flags they pass need gcc 12 or newer. Ubuntu 22.04's default `gcc` is 11, so the headers depend on `gcc-14 | gcc-13 | gcc-12` and use the newest one installed. On 22.04 that pulls in `gcc-12`. Kbuild warns that the compiler differs from the one the kernel was built with. That's expected, and it's fine for modules.

The host tools in the headers (`fixdep`, `modpost`, `genksyms`...) are built natively on arm64 against glibc 2.35, so they run on Ubuntu 22.04 and newer.

Tested on the board: a test module built against each kernel's headers and loaded on rk192 and rk192.1, and FriendlyElec's r8125 driver built against the rk192 headers.

## A/B SD card (optional)

`tools/mk-sdcard.sh` builds a microSD card that boots kernels from two slots with U-Boot's Android A/B logic. A new kernel boots once on trial and falls back to the known-good slot if it doesn't get marked good. The eMMC isn't touched, and pulling the card boots the eMMC as before. `tools/cm3588-slot` manages the slots (`status`, `mark-good`, `arm a --boots 1`).

It's how both builds here were tested. The gotchas I hit are in the comments of `mk-sdcard.sh` and `cm3588-slot`. The main one: U-Boot fails to read a 16M `second` stage from SD, so resource lives in its own per-slot partitions.

## Building

```
./build.sh                                # FriendlyElec tree in kernel/ (KSUFFIX=-fsfix2 for that suffix)
KDIR=wt-rk2 KSUFFIX=-rk192.1 ./build.sh   # Rockchip + stable tree
tools/mk-deb.sh <kver> <kernel.img|Image> <resource.img> <modules.tar.gz>
tools/mk-headers.sh <kdir> <kver>          # needs ssh to an arm64 box (ARM_HOST) to build the host tools
```

`build.sh` expects the kernel trees and FriendlyElec's `r8125` source checked out next to it, plus a 6.1.118 `resource.img` under `inputs/` (for the logos). How to rebuild the rk192 tree from Rockchip + stable is in [patches/rk192/README.md](patches/rk192/README.md).

## License

Kernel code and patches are GPL-2.0, like the kernel. The scripts in `tools/` are GPL-2.0 too.
