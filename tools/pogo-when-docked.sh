#!/bin/sh
# Probe the pogo STM32 ONLY while conn-detect actually reports docked.
# Run as root ON DEVICE.
#
# Every earlier run was muddied by the dock state changing mid-test: SW_DOCK
# has been observed 0, then 10, then 0 again, so conn-detect is live and
# working -- but we were probing i2c at moments when the keyboard was not
# electrically seated. That alone can explain every NACK we recorded.
#
# This waits for a stable dock, THEN runs the power sequence, and re-checks
# the dock afterwards so we can throw the result out if it moved.
#
# Already ruled out, do not re-test:
#   pin mux (gpio68/69 = qup18)   bus health (ENXIO = real NACK)
#   boot addr (0x51, hardcoded)   max77816 (display rail, not keyboard)

CHIP=gpiochip3; NRST=97; VDDO=70; BUS=0
DRV=/sys/bus/platform/drivers/reg-fixed-voltage
EV=/dev/input/event2

hold() { gpioset -c "$CHIP" "$1=$2" >/dev/null 2>&1 </dev/null & echo $!; }
drop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
docked() { evtest --query "$EV" EV_SW 5; [ $? -eq 10 ]; }

probe() {
	for a in 0x2a 0x51; do
		if out=$(i2cget -y -f "$BUS" "$a" 0x00 b 2>&1); then
			echo "    ** $a ACKed: $out **"
		else
			echo "    $a -> $out"
		fi
	done
}

echo "=== waiting up to 60s for a stable dock ==="
echo "    (seat the keyboard firmly and leave it alone)"
n=0
while [ $n -lt 60 ]; do
	if docked; then
		# require it to stay docked for 3 consecutive seconds
		s=0
		while [ $s -lt 3 ] && docked; do s=$((s+1)); sleep 1; done
		if [ $s -eq 3 ]; then echo "  docked and stable after ${n}s"; break; fi
	fi
	n=$((n+1)); sleep 1
done
if ! docked; then
	echo "  !! never reached a stable docked state — conn-detect says the"
	echo "     keyboard is not electrically seated. Nothing to probe."
	exit 1
fi

echo
echo "=== probe as-is (docked, rail as left by the regulator) ==="
probe

echo
echo "=== power sequence while docked ==="
DEV=""
for d in "$DRV"/*; do [ -L "$d" ] || continue; case "$(basename "$d")" in *pogo*) DEV=$(basename "$d");; esac; done
[ -z "$DEV" ] && { echo "  !! pogo regulator not bound"; exit 1; }
echo "$DEV" > "$DRV/unbind" || exit 1
sleep 1

PV=$(hold $VDDO 0); PN=$(hold $NRST 0); sleep 2
drop "$PV"; PV=$(hold $VDDO 1); sleep 1
drop "$PN"; PN=$(hold $NRST 1); sleep 1
echo "  +1s:"; probe
sleep 3
echo "  +4s:"; probe

drop "$PN"; drop "$PV"
echo "$DEV" > "$DRV/bind" && echo "  regulator rebound"

echo
echo "=== dock state AFTER the test (must still be docked to trust it) ==="
if docked; then echo "  still docked — result is valid"; else echo "  !! came undocked mid-test — RESULT INVALID, re-run"; fi
echo "=== done ==="
