import struct, time, select
f = open('/dev/input/event5', 'rb'); fmt = 'qqHHi'; sz = struct.calcsize(fmt)
out = open('/home/user/ev5.log', 'a', buffering=1); out.write(f"{time.strftime('%T')} start\n")
end = time.time() + 600
while time.time() < end:
    r, _, _ = select.select([f], [], [], 1.0)
    if r:
        s, us, t, c, v = struct.unpack(fmt, f.read(sz))
        if t: out.write(f"{time.strftime('%T')} type={t} code={c} value={v}\n")
