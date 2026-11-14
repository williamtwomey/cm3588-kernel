#!/bin/bash
# Reproducer for the 6.1.192 ext4 mballoc NULL-folio oops (stable-queue
# "ext4: fix NULL folio dereference in mballoc"). 6.1.192 backported mballoc's
# folio conversion with upstream's IS_ERR() checks, but in 6.1
# __filemap_get_folio() returns NULL. Once a group's buddy/bitmap page is
# evicted, the next allocation from that group oopses in
# ext4_mb_load_buddy_gfp().
#
#   tools/ext4-mballoc-repro.sh [rounds] [dir]
#
# Runs on a throwaway ext4 image on a loop device, so the real filesystems
# aren't involved. It's checked to reach the path that oopses (ext4_mb_init_cache
# after a fast-path miss, seen with ftrace), but it hasn't been run on an affected
# kernel. Expect an affected one to oops and wedge. Only run it with a way back in.
set -euo pipefail
ROUNDS=${1:-20}
DIR=${2:-/nvme/kernels}
[[ $(id -u) -eq 0 ]] || { echo "run as root"; exit 1; }
IMG=$(mktemp -p "$DIR" ext4-repro.XXXXXX.img)
MNT=$(mktemp -d)
LOOP=
cleanup() {
  umount "$MNT" 2>/dev/null || true
  [[ -n $LOOP ]] && losetup -d "$LOOP" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
  rm -f "$IMG"
}
trap cleanup EXIT
truncate -s 2G "$IMG"
mkfs.ext4 -q -F -b 4096 -G 1 "$IMG"   # no flex_bg packing, so writes spread over many groups
LOOP=$(losetup -f --show "$IMG")
mount "$LOOP" "$MNT"
K0=$(dmesg | grep -c -E 'Oops|BUG:|ext4_mb_load_buddy' || true)
for r in $(seq 1 "$ROUNDS"); do
  t0=$(date +%s.%N)
  for i in $(seq 0 15); do
    dd if=/dev/zero of="$MNT/f$i" bs=1M count=8 conv=fsync status=none
  done
  sync
  echo 3 > /proc/sys/vm/drop_caches
  for i in $(seq 0 15); do
    dd if=/dev/zero of="$MNT/g$i" bs=1M count=8 conv=fsync status=none
  done
  rm -f "$MNT"/f* "$MNT"/g*
  sync
  echo 3 > /proc/sys/vm/drop_caches
  K=$(dmesg | grep -c -E 'Oops|BUG:|ext4_mb_load_buddy' || true)
  printf 'round %d: %.1fs, new oops lines: %d\n' "$r" "$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{print b-a}')" $((K - K0))
  (( K == K0 )) || { echo "FAIL"; exit 1; }
done
echo "PASS: $ROUNDS rounds on $(uname -r)"
