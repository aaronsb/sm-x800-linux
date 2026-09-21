import mmap, os, sys, struct
addr=int(sys.argv[1],16); val=int(sys.argv[2],16); base=addr & ~0xfff
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
m=mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=base)
m[addr-base:addr-base+4]=struct.pack("<I", val)
print(f"wrote {sys.argv[1]} = 0x{val:08x}, readback 0x{struct.unpack('<I', m[addr-base:addr-base+4])[0]:08x}")
