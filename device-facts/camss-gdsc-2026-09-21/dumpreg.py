import mmap, os, sys
base=int(sys.argv[1],16); size=int(sys.argv[2],16); out=sys.argv[3]
fd=os.open("/dev/mem", os.O_RDONLY|os.O_SYNC)
m=mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
open(out,"wb").write(m[:size]); m.close(); os.close(fd); print("dumped", out)
