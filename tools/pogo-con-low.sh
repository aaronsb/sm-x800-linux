#!/bin/sh
# Drive the CON line LOW to trigger the keyboard's 1-Wire path. Run as root.
#
# WHY: strings from the stock keyboard firmware (48 KB, verified byte-identical
# to what is on the MCU) include:
#     "-------->>>> CON Low -> 1Wire 3.3V defance code!!"
#     "KBD_DISCONNECT_SAFETY_ENABLE!!"
#     "KBD READY!"
# So CON (tlmm gpio59) is not merely an attach-detect level -- pulling it LOW
# puts the keyboard into a 1-Wire signalling mode. Every experiment so far has
# only ever READ that pin. This is the first test that drives it.
#
# gpio59 is normally owned by our gpio-keys node (as the SW_DOCK switch), so we
# unbind gpio-keys to free it, and rebind at the end.
#
# Also note the firmware is an STM32G0 with TWO i2c peripherals
# (HAL_I2C_ErrorCallback / HAL_I2C2_ErrorCallback) and references an SLPI i2c
# path, so the AP bus may not be the only one it serves.
#
# READ ONLY with respect to flash. Nothing is written to the MCU.

CHIP=gpiochip3; CON=59; BUS=0
DRV=/sys/bus/platform/drivers/gpio-keys
FIFO=/tmp/pogo-con.fifo

cleanup() {
	[ -n "$GP" ] && kill "$GP" 2>/dev/null
	exec 3>&- 2>/dev/null
	rm -f "$FIFO"
	[ -n "$DEV" ] && echo "$DEV" > "$DRV/bind" 2>/dev/null
}
trap cleanup EXIT INT TERM

probe() {
	printf "    0x2a: "
	i2ctransfer -y -f "$BUS" r1@0x2a >/dev/null 2>&1 && echo "** ACK **" || echo "silent"
	printf "    sweep hits: "
	i2cdetect -y -r "$BUS" 2>/dev/null | tail -8 | grep -o '[0-9a-f][0-9a-f]' | grep -v '^--$' | tr '\n' ' '
	echo
}

for p in $(pgrep -x gpioset 2>/dev/null); do kill "$p" 2>/dev/null; done
sleep 1

echo "=== freeing gpio$CON from gpio-keys ==="
DEV=""
for d in "$DRV"/*; do
	[ -L "$d" ] || continue
	case "$(basename "$d")" in *gpio-keys*) DEV=$(basename "$d") ;; esac
done
[ -z "$DEV" ] && { echo "  !! gpio-keys not bound"; exit 1; }
echo "$DEV" > "$DRV/unbind" || exit 1
sleep 1
gpioinfo 2>/dev/null | grep -i "pogo-conn"

rm -f "$FIFO"; mkfifo "$FIFO" || exit 1
gpioset -c "$CHIP" -i "$CON=1" < "$FIFO" >/dev/null 2>&1 &
GP=$!
exec 3> "$FIFO"
sleep 1

echo
echo "=== baseline (CON released/high) ==="
probe

echo
echo "=== CON driven LOW, held 2s ==="
echo "set $CON=0" >&3
sleep 2
probe

echo
echo "=== CON LOW held 5s more (give the 1Wire/handshake path time) ==="
sleep 5
probe

echo
echo "=== CON pulsed low 100ms, then released ==="
echo "set $CON=1" >&3; sleep 1
echo "set $CON=0" >&3; usleep 100000; echo "set $CON=1" >&3
sleep 2
probe

echo
echo "=== CON pulsed low 500ms x3, then probe ==="
i=0
while [ $i -lt 3 ]; do
	echo "set $CON=0" >&3; usleep 500000
	echo "set $CON=1" >&3; usleep 500000
	i=$((i+1))
done
sleep 2
probe

echo
echo "=== attn line after all that ==="
gpioget -c "$CHIP" 71 2>&1

echo
echo "=== releasing CON, rebinding gpio-keys ==="
kill "$GP" 2>/dev/null; GP=""
sleep 1
echo "$DEV" > "$DRV/bind" && echo "  rebound" || echo "  !! rebind failed"
DEV=""
gpioinfo 2>/dev/null | grep -i pogo
echo "=== done ==="
