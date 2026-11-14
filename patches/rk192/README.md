# 6.1.192-rk192 tree

Rebuild:

    cd kernel && git remote add rockchip https://github.com/rockchip-linux/kernel.git  # if missing
    git fetch rockchip develop-6.1 && git fetch stable tag v6.1.192
    git worktree add -b cm3588-rk172-192 ../wt-rk2 77168c8d5ab82399f65a80e9f807b50ba37cf483
    cd ../wt-rk2 && git merge v6.1.192     # resolve as in 0000-*.remerge-diff
    git am ../patches/rk192/0*.patch
    cd .. && KDIR=wt-rk2 KSUFFIX=-rk192.1 ./build.sh   # -rk192 for the original, without 0015/0016

- Base: rockchip-linux/kernel develop-6.1 @ 77168c8d5ab8 (6.1.172, 2026-07-29)
- Merge: v6.1.192 -> 3ee24426e76d; the conflict resolutions are in 0000-merge-v6.1.192-resolutions.remerge-diff (git show --remerge-diff)
- On top: FriendlyElec board port + targeted fixes (0001-0014)
- rk192.1: 0015/0016 from stable-queue queue-6.1, fixing 6.1.192's NULL folio dereferences in ext4 mballoc and ntfs3 (6.1's __filemap_get_folio() returns NULL, the backports check IS_ERR)
- No ACK in the tree, so the found_cow double-unlock never existed here.
