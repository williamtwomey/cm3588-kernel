#!/usr/bin/env python3
"""Pack a kernel Image as a Rockchip KRNL image (what FriendlyElec's prebuilt
scripts/mkkrnlimg does): "KRNL" + le32 length + payload + le32 rkcrc32(payload).
rkcrc32 is CRC-32 with poly 0x04c10db7, MSB-first, init 0, no final xor.

  tools/mkkrnlimg.py Image kernel.img
  tools/mkkrnlimg.py --check kernel.img     # verify an existing image's CRC
"""
import struct
import sys

T = []
for i in range(256):
    c = i << 24
    for _ in range(8):
        c = ((c << 1) ^ 0x04C10DB7) if c & 0x80000000 else (c << 1)
    T.append(c & 0xFFFFFFFF)


def rkcrc(data):
    c = 0
    for b in data:
        c = ((c << 8) & 0xFFFFFFFF) ^ T[((c >> 24) ^ b) & 0xFF]
    return c


if sys.argv[1] == "--check":
    d = open(sys.argv[2], "rb").read()
    n = struct.unpack("<I", d[4:8])[0]
    ok = d[:4] == b"KRNL" and len(d) == n + 12 and struct.unpack("<I", d[8 + n:])[0] == rkcrc(d[8:8 + n])
    print("OK" if ok else "BAD")
    sys.exit(0 if ok else 1)
src, dst = sys.argv[1], sys.argv[2]
p = open(src, "rb").read()
open(dst, "wb").write(b"KRNL" + struct.pack("<I", len(p)) + p + struct.pack("<I", rkcrc(p)))
