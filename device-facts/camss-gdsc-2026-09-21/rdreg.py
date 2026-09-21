import mmap, os, sys, struct
for a in sys.argv[1:]:
    addr=int(a,16); base=addr & ~0xfff
    fd=os.open("/dev/mem", os.O_RDONLY|os.O_SYNC)
    m=mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    v=struct.unpack("<I", m[addr-base:addr-base+4])[0]
    print(f"{a} = 0x{v:08x}"); m.close(); os.close(fd)
