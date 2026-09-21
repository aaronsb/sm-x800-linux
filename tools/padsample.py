import mmap, os, sys, time, struct
# Sample the TLMM view of egpio pads (GPIO_IN_OUT bit 0) through /dev/mem.
# Usage on the tablet, as root: python3 padsample.py 171,172 2
# pinctrl-msm reads the same register for /sys/kernel/debug/gpio, so the read
# is safe on the pins that file lists. Issue #7, 2026-09-21.
pins = [int(p) for p in sys.argv[1].split(",")]
dur = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
maps = {p: mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xf100000 + p*0x1000) for p in pins}
ctl = {p: struct.unpack_from("<I", maps[p], 0)[0] for p in pins}
hist = {p: [0, 0] for p in pins}; trans = {p: 0 for p in pins}; last = {p: None for p in pins}; n = 0
t_end = time.monotonic() + dur
while time.monotonic() < t_end:
    for p in pins:
        v = struct.unpack_from("<I", maps[p], 4)[0] & 1
        hist[p][v] += 1
        if last[p] is not None and v != last[p]: trans[p] += 1
        last[p] = v
    n += 1
for p in pins:
    c = ctl[p]
    print(f"tlmm{p}: ctl=0x{c:04x} func={(c>>2)&0xf} oe={(c>>9)&1} egpio_present={(c>>11)&1} egpio_enable={(c>>12)&1} | in=0:{hist[p][0]} in=1:{hist[p][1]} transitions={trans[p]} (rounds={n})")
