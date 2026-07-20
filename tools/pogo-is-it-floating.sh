#!/bin/sh
# Decide whether tlmm gpio59's ~5 Hz oscillation is a REAL driven signal or just
# a floating input. Run as root ON DEVICE.
#
# WHY THIS MATTERS: we concluded from the oscillation that the keyboard MCU is
# alive and signalling. That conclusion is only valid if the pin is actually
# being DRIVEN. Two reasons to doubt it:
#   - stock sets bias-disable (no pull) on gpio59; a floating CMOS input picks
#     up noise from an attached-but-idle connector
#   - our gpio-keys debounce-interval is 30ms and the observed period was ~95ms,
#     which is ~3x the debounce timer. gpio-keys debouncing a noisy floating pin
#     produces exactly this kind of suspiciously REGULAR toggle.
#   - we already know our pinctrl is not fully applying: output-high on gpio97
#     never took effect (the line read back as "input"), so the bias config on
#     gpio59 may be ignored too and the pin left however ABL configured it.
#
# THE TEST: free the line from gpio-keys, then sample it with an explicit bias.
#   pull-up  -> reads consistently 1  AND
#   pull-down-> reads consistently 0   ==> FLOATING. "MCU is alive" is WRONG.
#   oscillates or holds one level regardless of bias ==> genuinely DRIVEN.
#
# Restores the gpio-keys binding at the end.

CHIP=gpiochip3
LINE=59
DRV=/sys/bus/platform/drivers/gpio-keys

sample() {   # $1 = bias, $2 = label
	# 20 reads over ~2s. A driven or pinned line gives a constant column;
	# a floating line follows whichever bias we apply.
	out=""
	i=0
	while [ $i -lt 20 ]; do
		v=$(gpioget -c "$CHIP" -b "$1" "$LINE" 2>/dev/null | sed 's/.*=//')
		case "$v" in
			*active) out="${out}1" ;;
			*inactive) out="${out}0" ;;
			*) out="${out}?" ;;
		esac
		i=$((i+1))
	done
	echo "  $2: $out"
}

echo "=== unbinding gpio-keys to free line $LINE ==="
DEV=""
for d in "$DRV"/*; do
	[ -L "$d" ] || continue
	case "$(basename "$d")" in *gpio-keys*) DEV=$(basename "$d") ;; esac
done
if [ -z "$DEV" ]; then
	echo "  !! gpio-keys not bound; devices present:"
	for d in "$DRV"/*; do [ -L "$d" ] && echo "    $(basename "$d")"; done
	exit 1
fi
echo "  device: $DEV"
echo "$DEV" > "$DRV/unbind" 2>&1 || { echo "  !! unbind failed"; exit 1; }
sleep 1
gpioinfo 2>/dev/null | grep -i "pogo-conn"

echo
echo "=== sampling line $LINE under three bias settings ==="
sample as-is      "no bias override "
sample pull-up    "bias=pull-up     "
sample pull-down  "bias=pull-down   "

echo
echo "=== edge count over 5s with pull-up (a driven signal still toggles) ==="
n=$(timeout 5 gpiomon -c "$CHIP" -b pull-up "$LINE" 2>/dev/null | wc -l)
echo "  edges with pull-up:   $n"
n=$(timeout 5 gpiomon -c "$CHIP" -b pull-down "$LINE" 2>/dev/null | wc -l)
echo "  edges with pull-down: $n"

echo
echo "=== INTERPRETATION ==="
echo "  pull-up all 1s AND pull-down all 0s, few edges  -> FLOATING (MCU not proven alive)"
echo "  toggles regardless of bias, many edges          -> genuinely DRIVEN"

echo
echo "=== rebinding gpio-keys ==="
echo "$DEV" > "$DRV/bind" 2>&1 && echo "  rebound" || echo "  !! rebind FAILED - vol-up/SW_DOCK gone until reboot"
gpioinfo 2>/dev/null | grep -i pogo
echo "=== done ==="
