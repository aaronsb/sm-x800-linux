#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline firmware patch: clean cleared RX status before buffer reuse.

Build: WLAN.HSP.1.1-03125-QCAHSPSWPL_V1_V2_SILICONZ_LITE-3.6510.41
Usage: python3 ath11k-rx-cache-clean.py amss.bin amss-patched.bin

At VA 0x01500fa8 (file offset 0x72fa8), change r1 = #12 to r1 = #104.
This extends the clean from [descriptor-8, descriptor+4) through
[descriptor-8, descriptor+0x60), covering the cleared attention words.
The only other change is the affected segment's SHA-256 integrity entry.

Requires the exact original SHA-256 below. Refuses signed containers and
existing output files. Does not install firmware or change authentication.
Experimental binary correction for review and porting to firmware source.
"""
import argparse
import hashlib
import os
import tempfile
from pathlib import Path
import struct

ORIGINAL_SHA256 = 'e12b23ddc4b8d2d2a10a651a5d6fdcd00f60fcae884d2cf5dad17627211fcdfd'
ADDRESS = 0x1500fa8
OLD = bytes.fromhex('81c10078')
NEW = bytes.fromhex('01cd0078')
PACKET_PREFIX = bytes.fromhex('c250418e')


def patch(original):
    if hashlib.sha256(original).hexdigest() != ORIGINAL_SHA256:
        raise ValueError('not the inspected original firmware')
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', original)
    # This vendor load container declares EM_ARM (40), despite containing
    # Hexagon instructions. Preserve its header; do not relabel the image.
    if header[0][:6] != b'\x7fELF\x01\x01' or header[2] != 40 or header[9] != 32:
        raise ValueError('unexpected ELF format')
    hits, segments = [], []
    for i in range(header[10]):
        segment = struct.unpack_from(
            '<8I', original, header[5] + i * header[9])
        segments.append(segment)
        kind, offset, virtual, _, size, _, flags, _ = segment
        if kind == 1 and flags & 1 and virtual + 4 <= ADDRESS and ADDRESS + 4 <= virtual + size:
            hits.append((i, offset + ADDRESS - virtual))
    if len(hits) != 1:
        raise ValueError('ambiguous instruction mapping')
    index, offset = hits[0]
    if original[offset-4:offset+4] != PACKET_PREFIX + OLD:
        raise ValueError('unexpected original instruction packet')
    result = bytearray(original)
    result[offset:offset+4] = NEW
    tables = [s for s in segments if s[6] & 0x7000000 == 0x2000000]
    if len(tables) != 1:
        raise ValueError('missing or ambiguous integrity table')
    table = tables[0]
    mbn = struct.unpack_from('<10I', original, table[1])
    if mbn[1] != 5 or any(mbn[i] for i in [2, 3, 7, 9]):
        raise ValueError('signed or unsupported container; authentication must not be changed')
    if mbn[4] != mbn[5] or mbn[5] != len(segments)*32 or table[4] != 40+mbn[5]:
        raise ValueError('unexpected integrity table length')
    for i, segment in enumerate(segments):
        at = table[1] + 40 + i*32
        expected = bytes(32) if segment == table or not segment[4] else hashlib.sha256(
            original[segment[1]:segment[1]+segment[4]]).digest()
        if original[at:at+32] != expected:
            raise ValueError(f'original segment {i} integrity mismatch')
    segment = segments[index]
    at = table[1] + 40 + index*32
    result[at:at+32] = hashlib.sha256(result[segment[1]:segment[1]+segment[4]]).digest()
    return bytes(result), offset


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('original', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        result, offset = patch(args.original.read_bytes())
        # Publish only a complete image; link() refuses an existing path.
        with tempfile.NamedTemporaryFile(dir=args.output.parent,
                                         prefix='.ath11k-rx-', delete=False) as stream:
            temporary = Path(stream.name)
            try:
                stream.write(result)
                stream.flush()
                os.fsync(stream.fileno())
                os.link(temporary, args.output)
            finally:
                temporary.unlink()
    except (OSError, ValueError) as exc:
        parser.exit(1, f'Error: {exc}\n')
    print(f'Patched image SHA256 {hashlib.sha256(result).hexdigest()}; instruction file offset {offset:#x}')


if __name__ == '__main__':
    main()
