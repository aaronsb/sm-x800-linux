#!/usr/bin/env python3
"""mk-tplg — derive the gts8pwifi AudioReach topology from the SM8450 HDK one.

The HDK topology (linux-msm/audioreach-topology, BSD-3-Clause; shipped by
linux-firmware as qcom/sm8450/SM8450-HDK-tplg.bin) already carries the
PRIMARY_MI2S_RX device graph this tablet needs. One value differs: the HDK
puts its I2S data on serial line SD0, while the Tab S8+ amplifiers listen on
SD1 (gpio128, mi2s0_data1 -- stock pri_tdm_dout; gpio127/SD0 is the
amplifiers' TX line back to the DSP). With SD0 the stream runs end to end
and the speakers stay silent.

The line index is a plain (token, value) u32 pair in the compiled topology:
AR_TKN_U32_MODULE_SD_LINE_IDX (256) with SD0 = 1, SD1 = 2. This script
finds that pair inside the I2S module's tuple array (the one that also
carries AR_TKN_U32_MODULE_HW_IF_TYPE/IDX, tokens 251/250) and sets it to
SD1. Everything else is byte-identical to the HDK file.

    tools/mk-tplg.py SM8450-HDK-tplg.bin Samsung-Galaxy-Tab-S8-Plus-tplg.bin

Re-run after a linux-firmware update if the HDK topology changes; the
output is committed in the device package so the device never needs this
script. A proper m4 build (SM8450-HDK.m4 with SD_LINE_IDX_I2S_SD1) is the
long-term form once alsatplg is in the build path.
"""
import struct
import sys

TOK_SD_LINE_IDX = 256
TOK_HW_IF_IDX = 250
TOK_HW_IF_TYPE = 251
SD0, SD1 = 1, 2


def main(src, dst):
    b = bytearray(open(src, "rb").read())
    hits = []
    for off in range(0, len(b) - 8, 4):
        tok, val = struct.unpack_from("<II", b, off)
        if tok != TOK_SD_LINE_IDX or val not in (SD0, SD1):
            continue
        # Genuine tuple arrays have the interface tokens just before.
        near = {struct.unpack_from("<I", b, o)[0] for o in range(max(0, off - 32), off, 8)}
        if TOK_HW_IF_IDX in near or TOK_HW_IF_TYPE in near:
            hits.append((off, val))
    if len(hits) != 1:
        sys.exit(f"!! expected exactly one I2S SD line token, found {hits}")
    off, val = hits[0]
    struct.pack_into("<II", b, off, TOK_SD_LINE_IDX, SD1)
    open(dst, "wb").write(b)
    print(f">> {src}: SD line idx at 0x{off:x} was {val}, now {SD1} (SD1) -> {dst}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
