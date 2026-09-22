import os, time
fd = os.open('/sys/kernel/debug/regmap/0-01/registers', os.O_RDONLY)
def rd(reg):
    b = os.pread(fd, 9, reg * 9)   # "8d08: 81\n"
    return int(b[6:8], 16)
out = open('/home/user/fastsample_long.log', 'a', buffering=1)
out.write(f"{time.strftime('%T')} start\n")
last = None; n = 0; t_end = time.time() + 2400; t0 = time.monotonic()
while time.time() < t_end:
    s1 = rd(0x8d08); rt = rd(0x8d10); lat = rd(0x8d18)
    cur = (s1 & 1, rt & 1, lat & 1)
    n += 1
    if cur != last:
        out.write(f"{time.monotonic()-t0:12.6f}s sample#{n} STATUS1.val={cur[0]} RT_STS.val={cur[1]} LATCHED={cur[2]} (raw s1=0x{s1:02x} rt=0x{rt:02x})\n")
        last = cur
out.write(f"{time.strftime('%T')} end samples={n} rate={n/(time.monotonic()-t0):.0f}/s\n")
