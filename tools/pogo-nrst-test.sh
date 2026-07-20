#!/bin/sh
# Targeted nRST experiment for the pogo STM32. Run as root ON THE DEVICE.
#
# Findings this is chasing (observed 2026-07-20 on the running device):
#   - tlmm line 97 "pogo-stm32-nrst" reads as an INPUT, i.e. the pinctrl
#     output-high state set in the DTS did NOT take effect. The MCU reset
#     line is floating, so the STM32 may be sitting in reset.
#   - SW_DOCK reads 0 (not docked) while the keyboard IS physically
#     attached, so conn-detect does not read the way stock describes.
#   - attn (line 71) reads high; stock uses IRQF_TRIGGER_LOW, so high is
#     the idle level and tells us nothing on its own.
#
# Deliberately does NOT run a full i2cdetect sweep: on a silent geni bus
# that is 112 sequential timeouts and takes minutes. Probes 0x2a/0x51 only.
#
# Any backgrounded gpioset MUST have its stdio detached or an ssh session
# will hang waiting on the fd. Killing gpioset must not match this script
# or the shell running it, hence the narrow pkill pattern.

CHIP=gpiochip3        # f100000.pinctrl (tlmm), 211 lines
NRST=97
BUS=0

cleanup_stale() {
	# A previous run that hung can leave gpioset holding the line, which
	# silently invalidates the whole experiment (the pulse never happens
	# because the request fails with EBUSY).
	for p in $(pgrep -x gpioset 2>/dev/null); do
		[ "$p" = "$$" ] && continue
		kill "$p" 2>/dev/null
	done
	sleep 1
}

hold() {   # $1 = value; echoes pid holding the line
	gpioset -c "$CHIP" "$NRST=$1" >/dev/null 2>&1 </dev/null &
	echo $!
}

release() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

probe() {
	for a in 0x2a 0x51; do
		if out=$(i2cget -y "$BUS" "$a" 0x00 b 2>&1); then
			echo "    ** $a ACKed: $out **"
		else
			echo "    $a silent"
		fi
	done
}

echo "=== clearing any stale gpioset holders ==="
cleanup_stale
gpioinfo 2>/dev/null | grep -i pogo

echo
echo "=== pogo_vddo rail ==="
for r in /sys/class/regulator/*; do
	n=$(cat "$r/name" 2>/dev/null)
	case "$n" in
		*pogo*) echo "  name=$n state=$(cat "$r/state" 2>/dev/null) status=$(cat "$r/status" 2>/dev/null)" ;;
	esac
done

echo
echo "=== line values (97 must NOT say busy, or the test is void) ==="
for l in 71 97 99; do
	printf "  line %s = %s\n" "$l" "$(gpioget -c $CHIP $l 2>&1)"
done

echo
echo "=== baseline (nRST floating) ==="
probe

echo
echo "=== nRST LOW 1s (assert reset) then HIGH (release), held ==="
P=$(hold 0); sleep 1; release "$P"
P=$(hold 1); sleep 2
echo "  probe immediately after release:"
probe
sleep 3
echo "  probe again after 3s settle (firmware boot time):"
probe
release "$P"

echo
echo "=== done ==="
