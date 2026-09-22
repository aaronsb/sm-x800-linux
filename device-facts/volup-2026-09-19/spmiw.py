# Userspace SPMI byte write to the pm8350 GPIO6 peripheral (SID 1, PID 0x8d) through
# arbiter v7 RW channel of APID 434, which EE0 owns. Usage: spmiw.py 0x8d41 0x00
import mmap, os, struct, sys, time
reg, val = int(sys.argv[1], 16), int(sys.argv[2], 16)
assert (reg >> 8) == 0x8d, "only the 0x8dxx peripheral (APID 434) is allowed"
APID = 434
fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
ch = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xc500000 + 0x1000 * APID)
def r32(o): return struct.unpack_from('<I', ch, o)[0]
def w32(o, v): struct.pack_into('<I', ch, o, v)
def rd(regaddr):
    f = os.open('/sys/kernel/debug/regmap/0-01/registers', os.O_RDONLY)
    b = os.pread(f, 9, regaddr * 9); os.close(f); return int(b[6:8], 16)
print(f"before: {reg:#06x} = {rd(reg):#04x}; channel status = {r32(0x08):#x}")
w32(0x10, val)                                   # WDATA0
w32(0x00, (0 << 27) | ((reg & 0xff) << 4) | 0)   # CMD: EXT_WRITEL, 1 byte
t0 = time.monotonic(); st = 0
while time.monotonic() - t0 < 0.01:
    st = r32(0x08)
    if st & 1: break
print(f"status = {st:#x} ({'DONE' if st & 1 else 'TIMEOUT'}{' FAILURE' if st & 2 else ''}{' DENIED' if st & 4 else ''}{' DROPPED' if st & 8 else ''})")
print(f"after : {reg:#06x} = {rd(reg):#04x}")
