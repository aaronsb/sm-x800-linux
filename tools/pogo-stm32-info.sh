#!/bin/sh
# Interrogate the pogo STM32 via its ROM bootloader. Run as root ON DEVICE.
#
# Holds BOOT0 (gpio99) HIGH across an nRST (gpio97) pulse so the MCU boots from
# mask ROM instead of its crash-looping application flash, then speaks the ST
# AN4221 I2C bootloader protocol at 0x51 via stm32boot.py.
#
# *** ONE COMMAND PER PULSE. *** The bootloader wedges after ANY stray or
# malformed traffic and then times out on everything until the next pulse:
#   - a bare read with no command pending returns 0x1F and poisons the state
#   - an incomplete/split command frame wedges it identically
# An earlier version of this script did a "confirm 0x51 is listening" bare read
# before handing off -- that confirmation check was itself what broke the thing
# it was checking. There is no probe here now, deliberately: the command's own
# 0x79 ACK is the proof it is alive.
#
# READ ONLY -- no erase, no write.

CHIP=gpiochip3; NRST=97; BOOT0=99; BUS=0
FIFO=/tmp/pogo-gpio.fifo
PY=${PY:-/tmp/stm32boot.py}

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

pulse() {
	echo "set $NRST=0"  >&3
	echo "set $BOOT0=1" >&3
	usleep 3000                # stock stm32_delay(3)
	echo "set $NRST=1"  >&3
	usleep 50000               # STM32_BOOT_I2C_STARTUP_DELAY
	# BOOT0 stays HIGH through the command so the ROM remains resident.
}

run() {   # $1 = heading, rest = stm32boot.py args
	h=$1; shift
	echo
	echo "=== $h ==="
	pulse
	python3 "$PY" "$BUS" "$@"
}

run "GET-ID (which STM32 is this?)"          getid
run "GET-VERSION"                            getver
run "GET (supported commands / RDP check)"   get
run "READ-MEMORY @ 0x08000000 (app flash)"   read 0x08000000 256

echo
echo "=== restoring run state (nrst=1, boot0=0) ==="
echo "set $BOOT0=0" >&3
echo "set $NRST=0"  >&3
usleep 3000
echo "set $NRST=1"  >&3
sleep 1
echo "=== done ==="
