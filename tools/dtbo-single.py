#!/usr/bin/env python3
"""Rewrite an Android DT table (dtbo.img) so every entry points at entry 0's overlay.

FriendlyElec's dtbo.img has one overlay per boot medium, and U-Boot picks the
entry by mmc devnum (board/rockchip/nanopi6/board.c: board_select_fdt_index).
Entry 0 (eMMC) carries `root=/dev/mmcblk2p8 ... data=/dev/mmcblk2p9`. Booting
from SD would pick entry 1, whose args point root at the card. We boot from SD
but keep the rootfs on eMMC, so every entry gets entry 0's blob.

usage: dtbo-single.py IN OUT
"""
import struct
import sys

HDR = ">8I"   # magic total_size header_size dt_entry_size dt_entry_count dt_entries_offset page_size version
ENT = ">8I"   # dt_size dt_offset id rev custom[4]
MAGIC = 0xD7B7AB1E

src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())
magic, total, hsize, esize, count, eoff, page, ver = struct.unpack_from(HDR, data, 0)
if magic != MAGIC:
    sys.exit(f"{src}: not a DT table (magic {magic:#x})")
e0 = struct.unpack_from(ENT, data, eoff)
print(f"{count} entries; entry 0 at {e0[1]:#x} size {e0[0]}")
for i in range(1, count):
    off = eoff + i * esize
    e = list(struct.unpack_from(ENT, data, off))
    print(f"  entry {i}: offset {e[1]:#x} -> {e0[1]:#x}")
    e[0], e[1] = e0[0], e0[1]
    struct.pack_into(ENT, data, off, *e)
open(dst, "wb").write(data)
