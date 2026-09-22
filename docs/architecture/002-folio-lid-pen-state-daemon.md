---
status: Draft
date: 2026-09-22
deciders:
  - aaronsb
  - claude
related:
  - https://github.com/aaronsb/sm-x800-linux/issues/33
  - https://github.com/aaronsb/sm-x800-linux/issues/46
  - https://github.com/aaronsb/sm-x800-linux/issues/41
---

# ADR-002: Folio, lid and pen state from pogo, hall switches and the magnetometer, as a system daemon with a virtual input device

## Context

The image is console only: fbcon on tty0, a getty on tty1, nobody logged
in until the operator types a password. The operator wants the tablet to
behave like a device before that point. The driving use cases, in the
operator's words:

- Open the folio and the screen lights up and the pen is usable.
- Close the folio and the screen turns off.
- Close the folio without the pen docked and the tablet flags the pen as
  possibly forgotten.
- The side power button does not light the screen while the folio is
  closed.
- With no folio present, or with the folio seated on the pogo pins, the
  power button toggles the screen off and on.
- All of this works with nobody logged in.

No single sensor on the board reports the folio. Issue #33 measured what
each one does with the Book Cover Keyboard folio on 2026-09-22.

Hall switches. Both work, level and interrupt, and both sit on the
`gpio-keys` node as EV_SW switches with wakeup-source. tlmm 169,
`SW_MACHINE_COVER`, is on the left edge about midway. This folio never
brings a magnet to that spot in any position, so it cannot produce a
cover-closed signal through the built-in sensor. A plain Book Cover with
a magnet on the left edge would. tlmm 23, `SW_PEN_INSERTED`, is on the
back face at the upper right corner. It reads asserted whenever the
folio is magnetically attached to the tablet but not seated on the pogo
pins, and when the pen is in the folio's holder. The pen's own magnet
does not trigger either sensor. On its own, tlmm 23 low means "folio
closed" or "pen in the holder" or "attached and lifted off the pins".

Pogo. The stm32-pogo driver registers the keyboard input device when the
MCU handshake completes and unregisters it on detach, so the device
exists only while docked. The tablet physically cannot be closed while
seated on the pogo pins, and every close in the session was preceded by
the driver's `conn: 0`. A present keyboard device is therefore a hard
"lid open". The MCU's own hall endpoint never reported anything.

Magnetometer. The AK09918 is not a kernel device. It is read through the
SLPI over fastrpc and libssc, `ssccli --sensor magnetometer`, with
`hexagonrpcd-sdsp.service` started at boot. Raw Z, in µT, with the tablet
in one place and orientation, each state held 4 to 5 s, within-state
spread under 3 µT on every axis:

| state | X | Y | Z |
|---|---|---|---|
| bare, pen away | 206 | 113 | 133 |
| bare, pen on the back strip, correct orientation | 158 | 117 | 359 |
| bare, pen on the back strip, reversed | 158 | 122 | 100 |
| in folio, open, docked, pen away | 289 | 211 | -305 |
| in folio, open, docked, pen on the back strip | 229 | 169 | -38 |
| folio closed, pen away | 209 | 187 | -477 |
| folio closed, pen in the folio holder | 214 | 174 | -462 |

Z carries almost everything. The pen on the strip adds about +225 on Z
bare and about +265 in the folio; reversed it subtracts about 30. X drops
by about 50 whenever a pen is on the strip in either orientation. The
folio takes Z to about -305 open and -477 closed. The pen in the holder
moves the closed reading by about 15. The clear-air total was 147 µT on
2026-09-21 and 270 µT on 2026-09-22 on the same sensor, so absolute
thresholds do not survive a change of desk. One state is unmeasured:
attached, open, off the pins.

Sampling cost. Every ssccli sample makes the SLPI toggle its SMP2P ready
and handover bits, and the kernel prints "Handover signaled, but it
already happened" once per sample, five times a second at ssccli's
default rate. Issue #46 tracks it. A daemon that streams the
magnetometer would keep that going for the life of the boot.

Display. DPMS off hangs the tablet about a minute later and it resets
itself, twice on 2026-09-22; issue #41 holds the record and the cause is
open. Device r26 ships `console-blank`, a system unit that unbinds fbcon
and zeroes fb0 after `BLANK_MIN` idle minutes and rebinds on any evdev
event. It opens every `/dev/input/event*` once at start, holds the
descriptors, and drains them every 2 s. It already owns blanking from a
system unit with nobody logged in. Suspend is untested. systemd-logind is
present with `HandlePowerKey=ignore` and `HandleLidSwitch=suspend`.

Platform. libssc is a GObject C API on GLib and GIO: a sensor is created
and opened asynchronously, reports through the GLib main loop, carries a
`sample-rate` property, and is closed the same way. The image has
`libssc.so.2` and `ssccli`; Alpine community ships `libssc-dev` with the
headers and pkg-config file, and `libevdev` with its `-dev` package.
pmbootstrap builds C in the device package cross-native, the way it
builds the kernel; a Rust aport builds in the aarch64 chroot under qemu
and fetches crates in prepare. The neighbouring components are C:
hexagonrpcd, libssc, iio-sensor-proxy and the port's own kernel drivers.
`CONFIG_INPUT_UINPUT=m` is set, the module is loaded, and `/dev/uinput`
is root 0600. `aplay` is present.

## Decision

A system daemon in the device package fuses three inputs and publishes
the result as a virtual input device. It runs as root from a `-systemd`
unit, needs nobody logged in, and starts before console-blank.

Inputs:

1. Presence of the pogo keyboard input device, watched through udev or
   the `/dev/input` directory.
2. The two `gpio-keys` switches, read as evdev events and queried at
   start.
3. Magnetometer samples through libssc: open the sensor, take the
   samples needed, close it. Taken when input 1 or 2 changes and on a
   slow heartbeat. No continuous stream.

Classification, one context at a time. The context is chosen by the
keyboard device and tlmm 23, and the magnetometer decides only within
that context:

| context | Z, X | state |
|---|---|---|
| keyboard present | Z above -150 | lid open, pen docked |
| keyboard present | otherwise | lid open, no pen |
| keyboard absent, tlmm 23 asserted | Z below -400 | lid closed |
| keyboard absent, tlmm 23 asserted | otherwise | attached, lifted off the pins, lid open |
| keyboard absent, tlmm 23 clear | Z above 250 | bare, pen docked |
| keyboard absent, tlmm 23 clear | Z 120 to 250 | bare, no pen |
| keyboard absent, tlmm 23 clear | Z 50 to 120 and X below 180 | bare, pen reversed |
| tlmm 169 asserted | any | plain cover closed |

The Z and X values in the table are the 2026-09-22 readings. The shipped
thresholds are the deltas between rows of the same context, applied to a
baseline the daemon holds for that context, since the clear-air field
moved by 123 µT between two days. Bare against bare-reversed is the thin
margin, 133 against 100 on Z, and X decides it.

Output: a uinput device carrying `SW_LID` and `SW_PEN_INSERTED`. `SW_LID`
is 1 in the lid-closed and plain-cover-closed rows and 0 otherwise.
`SW_PEN_INSERTED` on the virtual device is 1 in the pen-docked rows. The
raw `gpio-keys` switches keep their codes, `SW_MACHINE_COVER` and
`SW_PEN_INSERTED`, so the virtual device is the only `SW_LID` on the
system and logind sees exactly one lid switch.

Pen forgotten is a state transition the daemon logs: `SW_LID` goes to 1
and the last pen state known while the lid was open was "no pen". The
daemon records it and exposes it; console-blank or a later notifier acts
on it. How the operator is told is an open question. A short tone
through `aplay` is the first candidate.

Display policy stays with console-blank, extended to read the virtual
device. On `SW_LID` 1 it blanks. While `SW_LID` reads 1 no input event
unblanks, which covers the power button. On `SW_LID` 0 it unblanks and
resumes the idle timer. `KEY_POWER` from `pon_pwrkey` with `SW_LID` 0
toggles blank and unblank. logind is set to `HandleLidSwitch=ignore`, and
`HandlePowerKey=ignore` stays. No policy may suspend or power the panel
down until issue #41 is closed and suspend has been measured.

The daemon is the same class of code as stm32-pogo.c and the Wacom pen
driver in this port: hardware knowledge nothing generic can carry, owned
by the port.

Language: C. The daemon links libssc for the magnetometer and libevdev
for the switches, the keyboard device and the uinput device, and runs a
GLib main loop, which libssc needs anyway. It is built in the device
package with pmbootstrap's cross-native toolchain. The reasons, as facts:
libssc is a GLib C API with its own main loop and libevdev is C;
pmbootstrap builds C cross-native in seconds while a Rust aport builds in
the aarch64 chroot under qemu and fetches crates in prepare; and every
neighbouring component, hexagonrpcd, libssc, iio-sensor-proxy and the
port's kernel drivers, is C.

Design constraint: the state machine lives in one source file with no
GLib or libevdev types in it, plain C structs and functions. Its inputs
are keyboard present, hall 23, hall 169, and magnetometer X and Z; its
outputs are lid, pen and pen-forgotten. The sensor and uinput glue calls
it. That file can be unit-tested on the host and lifted into another
language later without touching the glue.

Reversibility: cheap. The virtual device is the interface. The daemon
behind it and its thresholds can change without touching console-blank,
logind or a future session layer, and the state machine file moves on
its own.

## Consequences

### Positive

- Every use case is met from a system unit with nobody logged in, on top
  of the two services the image already runs, console-blank and
  hexagonrpcd-sdsp.
- The kernel keeps reporting what the hardware does. The switches stay
  `SW_MACHINE_COVER` and `SW_PEN_INSERTED`, and the interpretation lives
  in userspace where the folio model can be changed.
- `SW_LID` on an input device is the signal logind, iio-sensor-proxy and
  every desktop session layer already understand, so a later Plasma
  session inherits lid behaviour with no extra work.
- The magnetometer is read only on a transition or a heartbeat, so the
  SMP2P toggling of issue #46 stays a handful of lines per event.
- The classifier is gated by two hard signals before the magnetometer
  is consulted, and each context has only two or three rows to separate
  with deltas of 170 to 265 µT against a spread under 3.
- The state machine is plain C in one file, so its table can be tested
  on the host against the 2026-09-22 readings before the daemon runs on
  the tablet.

### Negative

- Lid and pen state depend on the SLPI stack: hexagonrpcd, libssc, the
  served sensor tree and the registry. If the SLPI is down the daemon
  falls back to the two hard signals and cannot see the pen.
- The magnetometer is read raw. Rotating the tablet moves Earth's field,
  about 50 µT, between axes, and the baseline has to be re-learned when
  the field changes. The thin bare-against-reversed margin is where this
  costs.
- Two devices report `SW_PEN_INSERTED`: the raw switch means "magnet at
  tlmm 23" and the virtual one means "pen on the strip". A consumer that
  wants the fused meaning has to pick the virtual device.
- console-blank grows from an idle watcher into the display policy owner
  and gains a dependency on the daemon's device. Its enumerate-once
  start, already on issue #41, has to be fixed for it to see a device that
  appears later.
- Each sample is a libssc open, report and close over fastrpc on the
  close-to-blank path. The latency from close to blank is unmeasured.

### Neutral

- logind's `HandleLidSwitch` moves from suspend to ignore. Nothing was
  acting on a lid switch before, since no device reported one.
- The plain Book Cover row costs nothing now and is untested. tlmm 169 is
  already in the classifier.
- The pen-forgotten signal is defined as a transition, so how it reaches
  the operator can change without changing the daemon's state machine.

## Alternatives Considered

- Remap tlmm 23 to `SW_LID` in the device tree and let logind and
  console-blank act on it directly. Rejected: the switch is asserted with
  the pen in the holder and with the folio attached but lifted off the
  pins, so the screen would go dark in both of those open states, and it
  says nothing about the pen on the strip. It also puts a folio-specific
  interpretation into the kernel's description of the hardware.
- Leave it to a session layer: iio-sensor-proxy with its libssc backend
  plus a settings daemon in a desktop session. Rejected: nothing runs
  until someone logs in, which fails the operator's first requirement.
  iio-sensor-proxy's compass output stays useful to that layer later and
  is not displaced.
- Stream the magnetometer at ssccli's default rate and classify
  continuously. Rejected: issue #46 shows every sample toggles the SLPI's
  SMP2P bits and prints a kernel line, five times a second for the life
  of the boot.
- Absolute thresholds from the 2026-09-22 table. Rejected: the same
  sensor read a clear-air total of 147 µT the day before and 270 µT that
  day.
- Rust. Considered and not chosen. It was attractive for a long-running
  root daemon over file descriptors and timers, and for a likely future
  as a broader device-policy service with D-Bus, where the FFI cost would
  be paid once. Its two costs: FFI bindings for libssc would have to be
  written, and pmbootstrap would build it in the aarch64 chroot under
  qemu rather than cross-native, which is slow. The state machine file
  is the part that would move if that future arrives.

## Follow-ups

- Measure the unmeasured row: attached, open, off the pins, and confirm
  it lands above -400 on Z.
- Try a plain Book Cover, or a magnet at the left edge, and confirm the
  tlmm 169 row.
- Decide whether the 15 µT closed-state difference with the pen in the
  holder is usable, or whether pen-forgotten stays a carry-over from the
  last open state.
- Choose the heartbeat interval against the issue #46 idle count.
- Choose the pen-forgotten notification. `aplay` tone first.
- console-blank: rescan or restart on input add, already on issue #41,
  so a daemon restart does not leave it holding a dead descriptor.
