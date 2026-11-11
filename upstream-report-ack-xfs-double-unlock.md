# android14-6.1-lts: double ILOCK unlock in xfs_buffered_write_iomap_begin() (found_cow) hangs XFS reflink/overlayfs

**Affected:** `android14-6.1-lts` from the 6.1.138 merge (`4c7f06c5da94`, 2025-05-09) through at least 6.1.182 (checked 2026-11-11), and every downstream tree that merges it. Seen on FriendlyElec `nanopi6-v6.1.y` (RK3588, 6.1.141). Rockchip's `develop-6.1` (6.1.172) is **not** affected, because it doesn't carry the revert below.

## What happens

`fs/xfs/xfs_iomap.c`, `xfs_buffered_write_iomap_begin()`:

```c
found_cow:
	xfs_iunlock(ip, XFS_ILOCK_EXCL);          /* <- restored by the ACK revert */
	if (imap.br_startoff <= offset_fsb) {
		error = xfs_bmbt_to_iomap(ip, srcmap, &imap, flags, 0);
		if (error)
			goto out_unlock;              /* <- unlocks again */
		xfs_iunlock(ip, lockmode);            /* <- unlocks again */
		return xfs_bmbt_to_iomap(ip, iomap, &cmap, flags,
					 IOMAP_F_SHARED);
	}

	xfs_trim_extent(&cmap, offset_fsb, imap.br_startoff - offset_fsb);
	xfs_iunlock(ip, lockmode);                    /* <- unlocks again */
	return xfs_bmbt_to_iomap(ip, iomap, &cmap, flags, 0);
```

- `2061a2038206` (`Revert "xfs: use iomap_valid method to detect stale cached iomaps"`, 2024-07-26) put back the pre-iomap_valid early `xfs_iunlock(ip, XFS_ILOCK_EXCL)` at `found_cow:`.
- The 6.1.138 merge (`4c7f06c5da94`) brought in stable `0e2fcf273b67` ("xfs: match lock mode in xfs_buffered_write_iomap_begin()", upstream `bb712842a85d`). In upstream 6.1.y those `xfs_iunlock(ip, lockmode)` lines are the *only* unlocks in this block. In ACK they were kept alongside the restored early unlock.
- So every COW-fork buffered write drops the ILOCK twice. The rwsem state is corrupted, and the next `xfs_ilock()` on that inode sleeps forever.

The COW path is reached only on shared extents (reflink=1). overlayfs copy-up on XFS reflinks the lower file, so in practice this hits **Docker/containerd overlay2 on XFS**: containers hang in D state on their first chown/chmod/truncate of a copied-up file.

## Reproduce

Plain XFS with reflink=1 (the mkfs.xfs default), overlayfs on top, then `chown -R` across the merged tree to force copy-up. A self-contained script on a tmpfs-backed loop device: `tools/xfs-overlay-repro.sh` in this repo. It wedges in round 1 on 6.1.141 (FriendlyElec) and passes 20/20 rounds with the fix below. 6.1.118 (before the merge) passes.

```
INFO: task chown:3546 blocked for more than 122 seconds.
 xfs_ilock+0xd8/0xf4 [xfs]
 xfs_map_blocks+0xa0/0x394 [xfs]
 iomap_do_writepage+0x1e0/0x850
 write_cache_pages+0x1b4/0x41c
 iomap_writepages+0x2c/0x4c
 xfs_vm_writepages+0x8c/0xc8 [xfs]
 do_writepages+0x8c/0x1c0
 filemap_fdatawrite_wbc+0x80/0xc0
 __filemap_fdatawrite_range+0x64/0x98
 filemap_write_and_wait_range+0x44/0xb0
 xfs_setattr_size+0x2e0/0x380 [xfs]
 xfs_vn_setattr_size+0x54/0xa8 [xfs]
 xfs_vn_setattr+0x8c/0x160 [xfs]
 notify_change+0x1c0/0x520
 ovl_copy_up_metadata+0x238/0x320
 ovl_copy_up_one+0xa44/0x11cc
 ...
 chown_common+0x268/0x2d8
```

The flush kworker is stuck in `folio_wait_bit_common` and xfsaild is stuck too. Full traces: `evidence/6.1.141-stock-hung-tasks.txt`.

## Fix

Drop the stale early unlock. The block then matches upstream 6.1.y, apart from the iomap_valid sequence numbers that ACK reverted. Patch: `patches/0001-xfs-fix-double-ILOCK-unlock-in-xfs_buffered_write_io.patch`.

```diff
 found_cow:
-	xfs_iunlock(ip, XFS_ILOCK_EXCL);
 	if (imap.br_startoff <= offset_fsb) {
```

## Where to file

- Android Common Kernel: issuetracker.google.com, component "Android Public Tracker > Kernel" (needs a Google account), or a Gerrit change against `kernel/common` `android14-6.1-lts` (`BACKPORT`/`ANDROID:` fix with this description).
- FriendlyElec: an issue on github.com/friendlyarm/kernel-rockchip (`nanopi6-v6.1.y`), since their 6.1.141 deb ships the bug and their wiki points RK3588 NAS users at Docker on XFS.
