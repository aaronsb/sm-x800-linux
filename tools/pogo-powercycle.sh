#!/bin/sh
# Full power-sequence experiment for the pogo STM32. Run as root ON DEVICE.
#
# WHY: as shipped by our DTS the VDDO rail is regulator-always-on, so the MCU
# powers up at boot -- but nRST (tlmm 97) was observed stuck LOW at that
# moment, i.e. the STM32 came up held in reset and may have latched into a
# state it will not leave just because reset is later released. Driving nRST
# high alone was already tried and the MCU still NACKs.
#
# Ruled out by earlier runs, so do not re-test:
#   - pin mux: gpio68/69 are function qup18, claimed by 88c000.i2c
#   - bus health: probes return ENXIO (a real NACK), not a timeout
#   - accessory presence: SW_DOCK reads docked
#   - rail: pogo_vddo state=enabled
#
# To power-cycle we must free tlmm 70 from the fixed regulator that owns it.
# Unbinding reg-fixed-voltage releases the GPIO without a reflash. The rail is
# restored by rebinding at the end.

CHIP=gpiochip3
NRST=97
VDDO=70
BUS=0
DRV=/sys/bus/platform/drivers/reg-fixed-voltage

hold() { gpioset -c "$CHIP" "$1=$2" >/dev/null 2>&1 </dev/null & echo $!; }
drop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

probe() {
	for a in 0x2a 0x51; do
		if out=$(i2cget -y -f "$BUS" "$a" 0x00 b 2>&1); then
			echo "    ** $a ACKed: $out **"
		else
			echo "    $a -> $out"
		fi
	done
}

echo "=== locating the pogo fixed regulator ==="
DEV=""
for d in "$DRV"/*; do
	[ -L "$d" ] || continue
	b=$(basename "$d")
	case "$b" in *pogo*) DEV="$b" ;; esac
done
if [ -z "$DEV" ]; then
	echo "  !! no pogo device bound to reg-fixed-voltage; listing what is:"
	for d in "$DRV"/*; do [ -L "$d" ] && echo "    $(basename "$d")"; done
	exit 1
fi
echo "  found: $DEV"

echo
echo "=== unbinding so tlmm $VDDO becomes controllable ==="
echo "$DEV" > "$DRV/unbind" 2>&1 || { echo "  !! unbind failed"; exit 1; }
sleep 1
gpioinfo 2>/dev/null | grep -iE "pogo-vddo|pogo-stm32-nrst"

echo
echo "=== full sequence: power OFF + reset asserted ==="
PV=$(hold $VDDO 0)
PN=$(hold $NRST 0)
sleep 2
echo "  rail down, reset asserted for 2s"

echo "=== power ON (reset still asserted) ==="
drop "$PV"; PV=$(hold $VDDO 1)
sleep 1

echo "=== release reset ==="
drop "$PN"; PN=$(hold $NRST 1)
sleep 1
echo "  probe at +1s:"; probe
sleep 3
echo "  probe at +4s:"; probe

echo
echo "=== also sweep a few plausible addresses ==="
for a in 0x08 0x10 0x1a 0x2a 0x2b 0x38 0x39 0x50 0x51 0x60 0x68; do
	if i2cget -y -f "$BUS" "$a" 0x00 b >/dev/null 2>&1; then
		echo "    ** something at $a **"
	fi
done
echo "    (sweep done; only hits are printed)"

echo
echo "=== restoring ==="
drop "$PN"; drop "$PV"
echo "$DEV" > "$DRV/bind" 2>&1 && echo "  regulator rebound" || echo "  !! rebind failed - rail may be off until reboot"
gpioinfo 2>/dev/null | grep -i pogo
echo "=== done ==="
