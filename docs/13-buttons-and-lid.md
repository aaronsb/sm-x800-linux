# Phase 13: buttons and lid, a lid switch built from three sensors

Decision record: `docs/architecture/002-folio-lid-pen-state-daemon.md`.
Measurement record: issue #33 for the hall switches, the magnetometer and
the light sensor, PR #48 for the tablet tests. This page is the story of
one day, 2026-09-22: the morning found two hall switches that had never
toggled, the afternoon located them with a magnet and profiled the folio
with the magnetometer, and the evening ran the `folio-state` daemon and
device r27 on the tablet. The idle blanker it builds on is in
`docs/08-native-display.md`; the SLPI sensor stack it reads through is in
`docs/12-sensors.md`.

## The hardware

**Power and volume.** The power key and volume down are the pmk8350 PON
block, `pon_pwrkey` and `pon_resin`; the power key registers as the
`pmic_pwrkey` input device. Volume up is a `gpio-keys` line on pm8350
gpio6, active low with a pull-up, the way stock wires it. It works on
most boots; on some the PMIC latches two edges per press while the level
never changes, and issue #18 holds that investigation. The postmarketOS
initramfs polls volume down for its debug shell. systemd-logind runs
with `HandlePowerKey=ignore`, the postmarketOS default on this image, so
nothing acted on the power key before this phase.

**Hall switches.** Two, on the `gpio-keys` node as EV_SW switches with
`wakeup-source` and a 15 ms debounce, both active low. Stock calls them
`hall` and `hall_wacom` under a `hall_ic` node and routes them through
the PDC, tlmm 23 to PDC 54 and tlmm 169 to PDC 114. Located with a
strong magnet and `gpiomon`, tablet in landscape, screen toward the
operator, front camera at the top:

| line | code | location |
|---|---|---|
| tlmm 169 | `SW_MACHINE_COVER` | left edge, about midway, most responsive from the glass side |
| tlmm 23 | `SW_PEN_INSERTED` | back face, upper right corner |

With the Book Cover Keyboard folio, tlmm 23 reads asserted whenever the
folio is magnetically attached to the tablet but not seated on the pogo
pins, and whenever the pen is in the folio's holder. This folio never
brings a magnet to the tlmm 169 spot in any position, so it cannot
produce a cover-closed signal through the built-in sensor. A plain Book
Cover with a magnet on the left edge would. The pen's own magnet
triggers neither sensor, on the back strip in either orientation or
swept along every edge.

**The pogo keyboard.** `stm32-pogo` registers the keyboard input device
when the MCU handshake completes and unregisters it on detach, so the
device exists only while docked. The tablet cannot be closed while it
sits on the pogo pins, and every close in the session was preceded by
the driver's `conn: 0`. A present keyboard device is a hard "lid open".
The MCU's own hall endpoint, ep 4, never reported anything.

**Magnetometer and light.** The AK09918 magnetometer and the VEML3328
light sensor on the front face are not kernel devices. Both are read
through the SLPI over fastrpc and libssc, `ssccli --sensor magnetometer`
and `ssccli --sensor light`, with `hexagonrpcd-sdsp.service` up. Every
sample makes the SLPI toggle its SMP2P ready and handover bits, and the
kernel prints "Handover signaled, but it already happened" once per
sample. Issue #46 measured that the toggling stops when nothing streams.

## The measurements that shaped the design

**The hall investigation.** Kernel r26 on 2026-09-21 added the switches
and they read the stock idle levels, tlmm 23 low and tlmm 169 high. The
operator took the pen off and on and folded the cover while evtest
watched, and nothing changed. A second session on 2026-09-22 closed and
reopened the flap three times and swept the pen over the back and edges
with the same result, and the suspicion moved to a rail mainline leaves
off. That session ended in a silent hang after a minute of polling
`/sys/kernel/debug/gpio` at 5 Hz, which is why the README lists that
file under the gotchas.

The answer came on kernel r29 with `gpio-keys` unbound and the lines read
directly with `gpioget` and watched with `gpiomon`. Tlmm 23 changed state
when the tablet was lifted out of the folio, a rising edge 0.1 s before
the pogo driver logged `conn: 0`, so the interrupt path was fine. It had
never toggled under handling because the pen holder on this folio parks
the pen's magnet over that sensor, and the closed folio lands a magnet
there as well, so the line sits low on both sides of most moves. A
strong magnet swept over the tablet gave 6 edge pairs on tlmm 169 and 5
on tlmm 23 within 30 s. Both sensors work, level and interrupt, and
nothing was unpowered. Tlmm 23 by itself means "folio closed" or "pen in
the holder" or "attached and lifted off the pins", and while docked it
read high once and low once with the pen position unrecorded.

**The magnetometer profile.** Raw `ssccli` output in µT, uncalibrated,
tablet in the same place and orientation on one desk, each state held 4
to 5 s, within-state spread under 3 µT on every axis. "Docked" means
seated on the pogo pins.

| state | X | Y | Z | total |
|---|---|---|---|---|
| bare, pen away | 206 | 113 | 133 | 270 |
| bare, pen on the back strip, correct orientation | 158 | 117 | 359 | 409 |
| bare, pen on the back strip, reversed | 158 | 122 | 100 | 224 |
| in folio, open, docked, pen away | 289 | 211 | -305 | 470 |
| in folio, open, docked, pen on the back strip | 229 | 169 | -38 | 287 |
| folio closed, pen away | 209 | 187 | -477 | 554 |
| folio closed, pen in the folio holder | 214 | 174 | -462 | 538 |

Z carries almost everything. The pen on the strip adds about 225 on Z
bare and about 265 in the folio; reversed it subtracts about 30, since
the magnet is then at the far end of the strip. X drops by about 50
whenever a pen is on the strip in either orientation. The folio takes Z
to about -305 open and -477 closed. The pen in the folio holder moves the
closed reading by about 15, so the holder is far from the sensor. The
one thin margin is bare against bare-reversed, 133 against 100 on Z,
where X decides. The clear-air total was 147 µT on 2026-09-21 and 270 µT
on 2026-09-22 on the same sensor, so absolute thresholds do not survive
a change of desk. One state was not in the table: attached, open, off
the pins.

**Light.** `ssccli --sensor light` in one room light read 5 lux with the
folio open and docked and an exact 0 over four samples with the folio
closed. Open in a dim room earlier the same day read 6. A closed folio
and a dark room both read 0, so the sensor can rule out "closed" and
cannot confirm it.

## The design

ADR-002 in short. A system daemon fuses three inputs and publishes the
result as a virtual input device, so the tablet behaves like a device
with nobody logged in.

Two hard signals pick the context and the magnetometer decides only
inside it. The keyboard device present is the docked context. The
keyboard absent with tlmm 23 asserted is the attached context. Both
clear is the bare context. Tlmm 169 asserted is a plain cover closed in
any context. Inside a context the decision is a delta from a baseline
the daemon holds for that context, seeded from the table above and
re-learned from the first sample that classifies as open with no pen, so
a change of desk moves the baseline and the thresholds stay. While the
keyboard is present tlmm 23 is not consulted. A light reading above the
veto threshold moves a magnetometer "closed" to the open row of its
context; tlmm 169 is a hard signal and is not vetoed.

The magnetometer and the light sensor are sampled on every input
transition, on a heartbeat and on request, never streamed, so the issue
#46 toggling stays a handful of lines per event.

The output is a uinput device named `folio-state` carrying `SW_LID` and
`SW_PEN_INSERTED`. The raw `gpio-keys` switches keep their codes, so the
virtual device is the only `SW_LID` on the system. Pen forgotten is an
edge the daemon logs: the lid closes and the last open sample that could
see the strip saw no pen.

Display policy stays with `console-blank`, which reads the virtual
device: closed blanks and no input unblanks, the power button included;
open unblanks and restarts the idle timer; with the lid open the power
button toggles the console. logind is told to ignore the lid switch. No
policy suspends or powers the panel down, since DPMS off hangs the
tablet, issue #41.

The daemon is C, linking libssc and libevdev under a GLib main loop, and
the classifier is one plain C file with no GLib or libevdev in it, so it
runs on the host against the table and could move to another language
without touching the glue. Rust was considered and is recorded in the
ADR.

## What shipped

PR #48, on 2026-09-22, two packages.

**`folio-state` 0.1**, a new aport in `pmaports-overlay/temp/`, MIT,
built with `glib-dev`, `libssc-dev`, `libqmi-dev` and `libevdev-dev`.

- `folio_state.h` and `folio_state.c`: the classifier. Inputs are
  keyboard present, hall 23, hall 169, magnetometer X and Z, and light.
  Outputs are lid closed, pen docked, pen reversed, pen forgotten and the
  context. The table it implements, dZ and dX being the sample minus the
  context's baseline:

  | context | test | state |
  |---|---|---|
  | hall 169 asserted | any | plain cover closed |
  | keyboard present | dZ at or above `PEN_DZ_DOCKED` | lid open, pen docked |
  | keyboard present | otherwise | lid open, no pen |
  | keyboard absent, hall 23 asserted | dZ at or below minus `CLOSED_DZ` | lid closed |
  | keyboard absent, hall 23 asserted | otherwise | attached, off the pins, open |
  | keyboard absent, hall 23 clear | dZ at or above `PEN_DZ_BARE` | bare, pen docked |
  | keyboard absent, hall 23 clear | dZ at or below minus `REVERSED_DZ` and dX at or below minus `REVERSED_DX` | bare, pen reversed |
  | keyboard absent, hall 23 clear | otherwise | bare, no pen |

  The attached baseline is seeded from the docked one, since the
  attached-open row was unmeasured and closed is derived from
  docked-open. Without a magnetometer sample the classifier runs on the
  hard signals: keyboard present is open, hall 23 asserted without the
  keyboard is closed, hall 23 clear is open, and the pen holds its last
  value. The attached and closed rows also hold the pen, since neither
  can see the strip.
- `test_folio_state.c`: the seven measured rows in operator order, the
  pen-forgotten edge in both directions, the light veto at 5 and 0 lux,
  a start while closed, hall 169, no magnetometer, and baseline
  re-learning. `make check` runs it on the host, 47 checks.
- `foliod.c`: the daemon. It scans `/dev/input/event*` for `gpio-keys`
  and `Book Cover Keyboard*`, watches `/dev/input` with a GFileMonitor,
  reads the switch levels at open and reacts to EV_SW events. On each
  transition, on the heartbeat and on SIGUSR1 it opens, reads and closes
  the magnetometer and the light sensor through libssc, averages
  `MAG_SAMPLES` readings, steps the classifier and writes the two
  switches on the uinput device. The two libssc sensor objects are
  created once and kept for the life of the process. The libssc calls
  are the asynchronous ones: the synchronous wrappers retry discovery
  once a second for 100 s when hexagonrpcd is not serving, and a lid
  change must not wait on that. A sample past `SAMPLE_TIMEOUT_S` is
  abandoned and the daemon classifies on the hard signals until the next
  trigger. Every state change goes to stderr and so to the journal.
  `foliod --once` samples, prints the inputs and the classification, and
  exits without creating the virtual device.
- `folio-state.service`, in the `-systemd` subpackage: after and wanting
  `hexagonrpcd-sdsp.service`, before `console-blank.service`,
  `Restart=on-failure`, with a `multi-user.target.wants` symlink and a
  preset so `is-enabled` reads enabled.
- `/etc/conf.d/folio-state`, read by the unit as its environment file.
  Every key and its default:

  | key | default | meaning |
  |---|---|---|
  | `HEARTBEAT_S` | 60 | seconds between samples while nothing changes, bare and docked; 0 disables |
  | `ATTACHED_HEARTBEAT_S` | 3 | the same while attached but off the pins |
  | `LIGHT_VETO_LUX` | 2 | a reading strictly above this vetoes "lid closed" |
  | `PEN_DZ_BARE` | 112 | half the measured 225 |
  | `PEN_DZ_DOCKED` | 130 | half the measured 265 |
  | `REVERSED_DZ` | 15 | half the measured 30 |
  | `REVERSED_DX` | 25 | half the measured 50 |
  | `CLOSED_DZ` | 85 | half the measured 170 between docked-open and closed |
  | `BASE_Z_BARE` | 133 | baseline seed, bare row |
  | `BASE_X_BARE` | 206 | baseline seed, bare row |
  | `BASE_Z_DOCKED` | -305 | baseline seed, docked row and attached row |
  | `MAG_SAMPLES` | 3 | magnetometer readings averaged per sample |
  | `SAMPLE_TIMEOUT_S` | 10 | a sample slower than this falls back to the hard signals |
  | `PEN_FORGOTTEN` | off | `strip` logs the edge; off because this operator's pen lives in the holder |

**Device package r27.**

- `console-blank.sh` becomes the display policy owner. It locates the
  `folio-state` node at start and on every rescan and queries `SW_LID`
  with `evtest --query` on each 2 s tick; the node is queried, never
  held. Closed blanks the console and ignores all input, and input that
  arrives while closed is forwarded to foliod as SIGUSR1, since it is
  what the operator does on opening. Open again unblanks and restarts
  the idle count. With the lid open, bytes on the `pmic_pwrkey`
  descriptor toggle the console and every other device counts as
  activity. When the number of `/dev/input/event*` nodes changes the
  descriptors are closed and reopened, which closes the enumerate-once
  finding from issue #41. `console-blank status` now reports the lid.
- `80-gts8pwifi.preset` enables `console-blank` and `netinfo-console`,
  so `is-enabled` reads enabled for the vendor wants symlinks.
- `50-gts8pwifi-logind.conf`, installed as a logind drop-in, sets
  `HandleLidSwitch`, `HandleLidSwitchExternalPower` and
  `HandleLidSwitchDocked` to ignore. `HandlePowerKey` is untouched.
- The package depends on `folio-state` and `evtest`, and the `-systemd`
  subpackage on `folio-state-systemd`. `evtest` had lived only in the
  tools metapackage and is now a hard dependency.

## How it behaved on the tablet

**Folio-state r0.** Installed by hand over ssh with device r27, journals
and the fbcon bind watched at 0.5 s. The keyboard-present context was
right every time: the first classification read docked, lid open, no
pen, Z -314 against the -305 seed, light 5. A close that got a sample
classified closed, Z -438 against a base of -314, light 0. The
console-blank lid path traced with `sh -x` went `lid=closed`,
`console_on`, `blank`, then `unblank` on open, with fbcon unbound within
about 2 s of `SW_LID` going 1 and rebound within 2 s of it going 0. The
power button toggled the console with the lid open, bare and docked. The
rescan, the presets and the logind drop-in were all in place. The pen on
the strip while docked read Z 133 against a base of -305 and classified
pen docked.

Two defects and three smaller items:

1. **A libssc client leaked per sample.** The daemon created the two
   sensor objects on every sample, and each creation allocates a QMI
   client id on the SLPI that unref does not give back. With
   `HEARTBEAT_S=5` the SLPI answered `ClientIdsExhausted` after a few
   minutes, roughly 100 creations, then every sample failed with the
   QRTR bus unavailable until foliod restarted. The fix creates the two
   objects once and opens, reads and closes them per sample.
2. **No trigger while attached.** Lifting off the pins triggers a
   sample, but the close that follows changes only the magnetometer, so
   it was seen at the next heartbeat, 14 to 16 s late in one run, and
   missed in another where the folio was reopened first. The
   hard-signal fallback that ran after the leak had killed the sensors
   blanked in 2 s, so the path itself was fine. The fix is
   `ATTACHED_HEARTBEAT_S`, default 3, re-armed after every publish for
   the context in force, and the SIGUSR1 resample from console-blank.
3. libssc warned "Mount matrix provided by firmware is all 0" twice per
   sample. A GLib log writer drops it.
4. A failed sensor session logged two lines per attempt per heartbeat.
   Failures are now one line per sample, identical lines at most once a
   minute, plus a recovered line.
5. Pen forgotten fired on every close, because the pen lives in the
   folio holder and no sensor sees it there. `PEN_FORGOTTEN` gates the
   log line, default off, and the classifier is unchanged.

The 5 s heartbeat also filled the console with the issue #46 handover
lines; `dmesg -n 3` hid them for the session.

**Folio-state r1 stress test.** `HEARTBEAT_S=2`, docked throughout,
daemon up 550 s without restart, about 275 samples of magnetometer plus
light, zero sensor errors in the journal. Handover interrupts went from
3629 to 4113, 484 in 550 s, about 1.8 per sample. The journal stayed at
its six start-up lines: the mount-matrix filter and the unchanged
classification kept it silent.

**Timing after a reboot on r1**, logind now reading
`HandleLidSwitch=ignore`:

| monotonic s | event |
|---|---|
| 136.7 | lifted off the pins: attached, lid open, light 2, keyboard gone |
| 140.8 | folio closed: attached heartbeat sample, Z -382 against base -197, light 0, lid closed |
| 142.6 | fbcon unbound, console dark |
| 149.8 | folio opened without docking: SIGUSR1 from console-blank on input while closed, Z -131, light 6, lid open |
| 152.2 | fbcon rebound, console lit |
| 163.6 | docked: keyboard back, nothing to change |

Close to dark about 5 s, open to lit about 3 s, the tablet awake and on
the network throughout. Boot order: `hexagonrpcd-sdsp` at 14.1 s,
`folio-state` at 14.1 s, `console-blank` at 14.4 s, first classification
at 17.1 s.

All five ADR-002 use cases pass on this build with nobody logged in:
open the folio and the screen lights with the pen usable; close it and
the screen goes dark; close it without the pen on the strip and the
journal flags the pen, with `PEN_FORGOTTEN=strip`; press the power
button while closed and the screen stays dark; bare or docked, the power
button toggles the screen off and on.

## The suspend discovery

The first timing attempt, before the reboot, put the tablet into deep
suspend. The logind drop-in is read only at logind start, so logind was
still on its default `HandleLidSwitch=suspend` when the daemon published
its first `SW_LID` 1. The tablet stopped answering ping and ssh, and
about 13 minutes later one press of the power button resumed it with
the console lit, the keyboard re-handshaken, Wi-Fi reassociated on the
same address and the panel re-initialised through the suspend path.
That contradicts the working assumption in ADR-002 and issue #41 that
suspend would hit the DPMS hang. Issue #49 holds the resume trace and
the follow-ups. The packaging consequence is immediate: a hand install
of device r27 needs `systemctl restart systemd-logind` or a reboot before
the drop-in takes effect. `make install-tablet` reboots.

## By hand

```sh
sudo foliod --once                       # inputs and classification, no virtual device
console-blank status                     # BLANK_MIN, console state, panel dpms, lid and its node
journalctl -fu folio-state -u console-blank
sudo evtest /dev/input/eventN            # the "folio-state" node: SW_LID and SW_PEN_INSERTED live
evtest --query /dev/input/eventN EV_SW SW_LID   # exit 0 open, 10 closed
sudo kill -USR1 "$(systemctl show -p MainPID --value folio-state)"   # sample now
console-blank off; console-blank on      # blank and repaint by hand
dmesg -n 3                               # hide the issue #46 handover lines for a session
```

Settings live in `/etc/conf.d/folio-state`; `systemctl restart
folio-state` applies a change. A wrong row in `foliod --once` is a
threshold or baseline question and goes there. To locate a hall sensor,
unbind `gpio-keys` and run `gpiomon -c gpiochip3 23 169` with its output
sent to `/dev/tty1`, so the edges show on the tablet's own screen while
the magnet moves.

## Open

- The pen holder. The sensors cannot see the pen in the folio's holder
  apart from the 15 µT closed-state difference, so pen forgotten is off
  by default. Whether that 15 µT is usable is an ADR-002 follow-up.
- The attached, open, off-the-pins row is still not in the table. The
  timing test produced one such sample, Z -131 against a base of -197,
  and the seed for that context stays the docked baseline.
- A plain Book Cover, or a magnet on the left edge, to confirm the tlmm
  169 row. The classifier already carries it.
- The light veto threshold in daylight: closed in sunlight against open
  in a dark room, so the veto never fires on a closed folio.
- The handover line, issue #46. The heartbeat defaults keep it to a few
  lines per event; a ratelimit in the kernel handler is the upstream
  shape.
- Lid close to suspend. Suspend and resume work, issue #49, and a policy
  that uses them belongs in an ADR-002 amendment. Until then logind
  ignores the lid and console-blank owns the display.
- The pen-forgotten notification. An `aplay` tone is the first
  candidate; today it is a journal line.
- The power button counts bytes on the `pmic_pwrkey` descriptor, so a
  press whose down and up straddle a 2 s poll boundary would toggle
  twice. Not seen in the tests; the fix, if needed, counts `KEY_POWER`
  press records.
- Volume up, issue #18.
