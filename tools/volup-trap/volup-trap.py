#!/usr/bin/env python3
# Volume Up trap (issue #18): logs every KEY_VOLUMEUP event from gpio-keys, and when the
# pm8350 GPIO 6 interrupt count rises with no key event in the same window, records the
# dead state (PMIC GPIO 6 block, all GPIO chips, regulators, full PMIC regmaps once an hour).
import os, re, struct, select, time, glob, subprocess
LOG = '/home/user/volup-trap/trap.log'; DIR = '/home/user/volup-trap'
os.makedirs(DIR, exist_ok=True)
log = open(LOG, 'a', buffering=1)
def now(): return time.strftime('%Y-%m-%d %H:%M:%S')
def find_event():
    for d in glob.glob('/sys/class/input/event*'):
        if open(d + '/device/name').read().strip() == 'gpio-keys': return '/dev/input/' + os.path.basename(d)
def irq_count():
    for line in open('/proc/interrupts'):
        if 'Volume Up' in line: return sum(int(x) for x in line.split()[1:9])
    return -1
def capture(tag, full):
    stamp = time.strftime('%Y%m%d-%H%M%S'); p = f'{DIR}/{tag}-{stamp}'
    with open(p + '.txt', 'w') as f:
        f.write(f'# {now()} {tag} uptime={open("/proc/uptime").read().split()[0]}s\n')
        f.write(subprocess.run(['grep', '-E', '^8d[0-5][0-9a-f]:', '/sys/kernel/debug/regmap/0-01/registers'], capture_output=True, text=True).stdout)
        f.write('# /proc/interrupts\n' + open('/proc/interrupts').read())
        f.write('# /sys/kernel/debug/gpio\n' + open('/sys/kernel/debug/gpio').read())
        f.write('# regulators\n')
        for r in glob.glob('/sys/class/regulator/regulator.*'):
            try: f.write(f"{open(r+'/name').read().strip()}={open(r+'/state').read().strip()}\n")
            except Exception: pass
    if full:
        for d in ('0-00', '0-01', '0-02'):
            with open(f'{p}-pmic-{d}.txt', 'w') as f: f.write(open(f'/sys/kernel/debug/regmap/{d}/registers').read())
    log.write(f'{now()} captured {p} full={full}\n')
dev = None; fmt = 'qqHHi'; sz = struct.calcsize(fmt)
last_irq = irq_count(); last_check = time.time(); events_in_window = 0; last_full = 0
log.write(f'{now()} start irq={last_irq} uptime={open("/proc/uptime").read().split()[0]}s\n')
capture('boot', False)
while True:
    if dev is None:
        e = find_event()
        if e: dev = open(e, 'rb'); log.write(f'{now()} watching {e}\n')
        else: time.sleep(5); continue
    r, _, _ = select.select([dev], [], [], 1.0)
    if r:
        s, us, t, c, v = struct.unpack(fmt, dev.read(sz))
        if t == 1: events_in_window += 1; log.write(f'{now()} KEY code={c} value={v} irq={irq_count()}\n')
    if time.time() - last_check >= 10:
        cur = irq_count()
        if cur > last_irq and events_in_window == 0:
            full = time.time() - last_full > 3600
            log.write(f'{now()} DEAD-STATE irq {last_irq}->{cur} with no key event\n')
            capture('dead', full)
            if full: last_full = time.time()
        elif cur > last_irq:
            log.write(f'{now()} OK irq {last_irq}->{cur} events={events_in_window}\n')
        last_irq = cur; events_in_window = 0; last_check = time.time()
