#!/usr/bin/env python3
"""Losslessly shrink an .icns after `oxipng -o max --strip safe` on its
iconset (the icnsoptim approach — github.com/sveinbjornt/icnsoptim).

iconutil re-encodes PNGs on packing, discarding any optimisation, so this
rebuilds the container directly: PNG chunks are replaced with the
optimised iconset files, the 16/32px ARGB chunks (ic04/ic05 — Apple's
own format for those sizes) are kept verbatim from the existing icns,
and the redundant `info` name plist is dropped.

Usage: repack-icns.py current.icns optimised.iconset out.icns
"""
import struct
import sys
from pathlib import Path

PNG_FOR = {  # icns type code -> iconset filename
    "ic07": "icon_128x128.png", "ic13": "icon_128x128@2x.png",
    "ic08": "icon_256x256.png", "ic14": "icon_256x256@2x.png",
    "ic09": "icon_512x512.png", "ic10": "icon_512x512@2x.png",
    "ic11": "icon_16x16@2x.png", "ic12": "icon_32x32@2x.png",
}

src = Path(sys.argv[1]).read_bytes()
iconset = Path(sys.argv[2])
chunks = b""
off = 8
while off < len(src):
    code = src[off:off + 4].decode()
    length = struct.unpack(">I", src[off + 4:off + 8])[0]
    if code in PNG_FOR:
        data = (iconset / PNG_FOR[code]).read_bytes()
        chunks += code.encode() + struct.pack(">I", len(data) + 8) + data
    elif code != "info":
        chunks += src[off:off + length]
    off += length
out = b"icns" + struct.pack(">I", len(chunks) + 8) + chunks
Path(sys.argv[3]).write_bytes(out)
print(f"{sys.argv[3]}: {len(src)} -> {len(out)} bytes")
