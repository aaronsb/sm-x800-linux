#!/bin/sh
# Quick pogo state readout. Run as root ON DEVICE. READ ONLY.
#
# NOTE ON DOCK STATE: conn-detect toggles at ~5 Hz whenever the keyboard is
# attached, so a point sample (evtest --query) returns essentially a random
# answer. The EDGE COUNT is the trustworthy signal:
#     ~50 edges/5s  -> attached (MCU cycling its connect sequence)
#     ~0-1 edges/5s -> detached
EV=/dev/input/event2
CHIP=gpiochip3
BUS=0

evtest --query "$EV" EV_SW 5
[ $? -eq 10 ] && DOCK=docked || DOCK=undocked
echo "  SW_DOCK (unreliable): $DOCK"
echo "  conn edges/5s       : $(timeout 5 evtest "$EV" 2>/dev/null | grep -c SW_DOCK)"
echo "  attn  (gpio71)      : $(gpioget -c $CHIP 71 2>&1)   [high = idle]"
echo "  nrst  (gpio97)      : $(gpioget -c $CHIP 97 2>&1)   [high = out of reset]"
echo "  swclk (gpio99)      : $(gpioget -c $CHIP 99 2>&1)   [low = app, high = ROM]"
echo "  vddo rail           : $(grep -i pogo /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | awk '{print $1, $2}')"

printf "  0x2a (keyboard app) : "
i2ctransfer -y -f "$BUS" r1@0x2a >/dev/null 2>&1 && echo "ACK" || echo "silent"

echo "  --- pin mux (68/69 must read qup18; 46 is the touchscreen IRQ) ---"
PMX=/sys/kernel/debug/pinctrl/f100000.pinctrl/pinmux-pins
if [ -f "$PMX" ]; then
	grep -E "pin (46|59|68|69|70|71|97|99)\b" "$PMX" 2>/dev/null | sed 's/^/    /'
else
	echo "    (pinmux-pins not readable)"
fi

echo "  --- i2c adapters ---"
for d in /sys/bus/i2c/devices/i2c-*; do
	[ -e "$d/name" ] && echo "    $(basename "$d") = $(cat "$d/name")"
done
