# 6.1.193-rk193 tree

rk192 (without 0015/0016) merged with stable v6.1.193. Rebuild:

    # first the rk192 tree, as in ../rk192/README.md, through 0014 (not 0015/0016)
    cd wt-rk2 && git checkout -b cm3588-rk193 <rk192 0014 commit>
    git fetch stable tag v6.1.193 && git merge v6.1.193   # resolve as in 0000-*.remerge-diff
    cd .. && KDIR=wt-rk2 KSUFFIX=-rk193 ./build.sh

`git apply` takes the remerge-diff directly once the conflict markers carry the same
labels as in the diff (`<<<<<<< be5164e93136 (...)` / `>>>>>>> 1ca1436ccc68 (Linux 6.1.193)`);
rewrite git's `HEAD` / `v6.1.193` labels to match first.

- rk192's 0015/0016 (ext4 mballoc and ntfs3 NULL folio) are upstream in 6.1.193
  (`057d0a4c6def`, `9929bfa37666`), so they're dropped.
- 17 conflicts; the resolutions and why are in the merge commit message at the top of
  0000-merge-v6.1.193-resolutions.remerge-diff. The ones that matter on RK3588: GIC ITS
  (stable's allocation refactor; Rockchip's rk3588 shareability quirks merged cleanly),
  rockchip-iommu (both sides), usb quirks (Rockchip's AUTO_SUSPEND moved to BIT(20),
  stable took BIT(19)).
- `arch/arm64/boot/dts/rockchip` is Rockchip's whole directory. .193 has no rk3588 DTS
  changes, and the CM3588 resource.img comes out byte-identical to rk192.1's.
