#!/bin/sh
# Settle a question open since the start: is the STM32 in the TABLET or in the
# KEYBOARD? Run as root ON DEVICE, once detached and once attached.
#
# The ROM bootloader is the ideal probe because it does not depend on the
# (faulting) application firmware -- it is in mask ROM and always runs when
# BOOT0 is high across an nRST pulse.
#
#   bootloader ACKs while DETACHED -> MCU lives in the TABLET
#   bootloader silent while DETACHED -> MCU lives in the KEYBOARD
#
# This matters a lot:
#  - it decides whether the ~5 Hz conn-detect signal is the MCU resetting or
#    something else entirely
#  - it decides whether a future reflash risks bricking a detachable ACCESSORY
#    or the TABLET's own silicon (very different risk profiles)
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

echo "=== dock state ==="
evtest --query "$EV" EV_SW 5
[ $? -eq 10 ] && echo "  SW_DOCK = DOCKED" || echo "  SW_DOCK = UNDOCKED"
echo "  conn-detect edges in 5s: $(timeout 5 evtest "$EV" 2>/dev/null | grep -c SW_DOCK)"

echo
echo "=== pulse into ROM bootloader and ask GET-ID ==="
# No pre-probe: a bare read would poison the bootloader state (see stm32boot.py).
echo "set $NRST=0"  >&3
echo "set $BOOT0=1" >&3
usleep 3000
echo "set $NRST=1"  >&3
usleep 50000
python3 "$PY" "$BUS" getid
rc=$?

echo
echo "=== second attempt (fresh pulse, GET-VERSION) ==="
echo "set $NRST=0"  >&3
usleep 3000
echo "set $NRST=1"  >&3
usleep 50000
python3 "$PY" "$BUS" getver

echo
echo "=== third attempt: raw address ACK at 0x51 ==="
echo "set $NRST=0"  >&3
usleep 3000
echo "set $NRST=1"  >&3
usleep 50000
if i2ctransfer -y -f "$BUS" r1@0x51 >/dev/null 2>&1; then
	echo "  0x51 acknowledged the address"
else
	echo "  0x51 did NOT acknowledge (ENXIO)"
fi

echo
echo "=== VERDICT ==="
echo "  If this run was with the keyboard DETACHED and 0x51 answered,"
echo "  the MCU is in the TABLET. If it went silent, it is in the KEYBOARD."

echo
echo "=== restoring run state ==="
echo "set $BOOT0=0" >&3
echo "set $NRST=0"  >&3
usleep 3000
echo "set $NRST=1"  >&3
sleep 1
echo "=== done ==="
