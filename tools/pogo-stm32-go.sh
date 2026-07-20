#!/bin/sh
# Use the ROM bootloader's GO command to jump straight into the application
# firmware, then watch whether the MCU comes alive. Run as root ON DEVICE.
#
# WHY: READ-MEMORY proved the app image is PRESENT with a textbook-valid
# Cortex-M vector table (SP 0x200056a8 into SRAM, reset PC 0x0800b6ad in flash
# with the thumb bit set). So flash is not blank and not corrupt at the start --
# yet on a normal reset the MCU crash-loops at ~5 Hz and never answers at 0x2a.
#
# GO jumps to the app from a known-good bootloader state, bypassing whatever
# happens during a normal power-on. It writes NOTHING; it is non-destructive.
#
#   app answers at 0x2a after GO -> firmware is FINE; the fault is in how the
#                                   MCU enters the app on a normal reset
#   app still silent, still 5 Hz  -> the fault is inside the image itself
#
# Note BOOT0 must be driven LOW before GO, otherwise the app would re-enter the
# bootloader on any internal reset.
#
# READ ONLY.

CHIP=gpiochip3; NRST=97; BOOT0=99; BUS=0
FIFO=/tmp/pogo-gpio.fifo
PY=${PY:-/tmp/stm32boot.py}
EV=/dev/input/event2

cleanup() {
	[ -n "$GP" ] && kill "$GP" 2>/dev/null
	exec 3>&- 2>/dev/null
	rm -f "$FIFO"
}
trap cleanup EXIT INT TERM

for p in $(pgrep -x gpioset 2>/dev/null); do kill "$p" 2>/dev/null; done
sleep 1
rm -f "$FIFO"; mkfifo "$FIFO" || exit 1
gpioset -c "$CHIP" -i "$NRST=1" "$BOOT0=0" < "$FIFO" >/dev/null 2>&1 &
GP=$!
exec 3> "$FIFO"
sleep 1

probe2a() {
	printf "    0x2a: "
	if out=$(i2ctransfer -y -f "$BUS" r1@0x2a 2>&1); then
		echo "** ACKed -> $out **"
	else
		echo "silent"
	fi
}

edges() { timeout 5 evtest "$EV" 2>/dev/null | grep -c SW_DOCK; }

echo "=== BEFORE: normal app boot (nrst pulse, BOOT0 low) ==="
echo "set $NRST=0" >&3; usleep 3000; echo "set $NRST=1" >&3; sleep 1
probe2a
echo "    conn-detect edges in 5s: $(edges)"

echo
echo "=== pulse into ROM bootloader (BOOT0 high) ==="
echo "set $NRST=0"  >&3
echo "set $BOOT0=1" >&3
usleep 3000
echo "set $NRST=1"  >&3
usleep 50000

echo "=== drop BOOT0 low, then GO 0x08000000 ==="
# BOOT0 low first so any internal reset inside the app does not bounce us back
# into the bootloader.
echo "set $BOOT0=0" >&3
usleep 5000
python3 "$PY" "$BUS" go 0x08000000

echo
echo "=== AFTER GO: is the application alive? ==="
sleep 1
probe2a
echo "    conn-detect edges in 5s: $(edges)"
sleep 2
echo "  second look:"
probe2a
echo "    conn-detect edges in 5s: $(edges)"

echo
echo "=== attn line (gpio71) -- app asserts it LOW when it has data ==="
gpioget -c "$CHIP" 71 2>&1

echo
echo "=== restoring run state ==="
echo "set $BOOT0=0" >&3
echo "set $NRST=0"  >&3
usleep 3000
echo "set $NRST=1"  >&3
sleep 1
echo "=== done ==="
