#!/bin/bash
# Gate test for the 6.1.141 XFS hang: Docker containers stuck in D state when
# chowning at startup, i.e. overlayfs copy-up onto XFS (overlay2 on /nvme).
#
# Builds overlayfs on a loop XFS whose backing file is on tmpfs, so a hang
# can't take the real /nvme with it. Then does chown -R across the merged tree
# (forcing copy-up of every file) a few rounds, with a timeout and a D-state check.
#
#   sudo tools/xfs-overlay-repro.sh [rounds] [files]
# Exit 0 = clean, 1 = hang/D-state seen. On a hang, reboot; the loop/tmpfs can't be unmounted.
set -uo pipefail
ROUNDS=${1:-5}
FILES=${2:-20000}
W=/run/xfsrepro
TIMEOUT=300

cleanup() { umount -R "$W/xfs" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; umount "$W" 2>/dev/null; rmdir "$W" 2>/dev/null; }
N0=$(dmesg | wc -l)
mkdir -p "$W" && mount -t tmpfs -o size=3G tmpfs "$W"
truncate -s 2800M "$W/img"
LOOP=$(losetup -f --show "$W/img")
trap cleanup EXIT
modprobe xfs
# Same mkfs features as /nvme (reflink, crc, ftype) so the code paths match.
mkfs.xfs -q -f -m reflink=1,crc=1 -n ftype=1 "$LOOP"
mkdir -p "$W/xfs" && mount -t xfs "$LOOP" "$W/xfs"
echo "kernel $(uname -r); xfs on $LOOP; $ROUNDS rounds x $FILES files"

fail=0
for r in $(seq 1 "$ROUNDS"); do
  D=$W/xfs/r$r; mkdir -p "$D"/{lower,upper,work,merged}
  # lower layer: lots of small files plus some larger ones, across nested dirs, like an image layer
  for i in $(seq 1 $((FILES / 100))); do
    mkdir -p "$D/lower/d$i"
    for j in $(seq 1 100); do echo "$r $i $j" > "$D/lower/d$i/f$j"; done
  done
  for i in 1 2 3 4; do head -c 32M /dev/urandom > "$D/lower/big$i"; done
  mount -t overlay overlay -o "lowerdir=$D/lower,upperdir=$D/upper,workdir=$D/work" "$D/merged"
  start=$(date +%s)
  timeout -s KILL $TIMEOUT chown -R 1000:1000 "$D/merged" &
  cpid=$!
  ( timeout -s KILL $TIMEOUT find "$D/merged" -type f -exec chmod g+w {} + ) &
  fpid=$!
  wait $cpid; c=$?; wait $fpid; f=$?
  dur=$(( $(date +%s) - start ))
  # Only our own workers, and only if they stay in D across samples (transient D during I/O is normal).
  dstate=0
  for s in 1 2 3; do
    n=$(ps -eo stat,comm | awk '$1 ~ /^D/ && $2 ~ /^(chown|find|chmod)$/' | wc -l)
    [[ $n -gt 0 ]] && dstate=$n || { dstate=0; break; }
    sleep 5
  done
  echo "round $r: chown rc=$c chmod rc=$f ${dur}s, D-state procs=$dstate"
  if [[ $c -ne 0 || $f -ne 0 || $dstate -gt 0 ]]; then fail=1; break; fi
  umount "$D/merged"
done
dmesg | tail -n +$((N0 + 1)) | grep -E "blocked for more than|hung_task|INFO: task|XFS .*(rror|orrupt|hutdown)|overlayfs: .*rror" | tail -20 | grep . && fail=1
if [[ $fail -eq 0 ]]; then echo "PASS"; else
  echo "FAIL"
  # Only skip cleanup if something is actually wedged: umount on a hung fs would hang too.
  if ps -eo stat,comm | awk '$1 ~ /^D/ && $2 ~ /^(chown|find|chmod)$/' | grep -q .; then
    echo "processes stuck in D; leaving mounts alone, reboot to clear"; trap - EXIT
  fi
fi
exit $fail
