#!/bin/sh
# flashtest.sh : rear flash LED demo, run as user with sudo (issue #26).
# Torch 5 s at the given brightness (0..255 = 0..500 mA total, stock's
# torch is 77), off, then one 300 mA strobe with a 200 ms hardware timeout.
L=/sys/class/leds/white:flash
B=${1:-200}
[ -d "$L" ] || { echo "no $L"; exit 1; }
echo "torch on: brightness $B for 5 s"
echo "$B" | sudo tee $L/brightness >/dev/null
sleep 5
echo 0 | sudo tee $L/brightness >/dev/null
echo "torch off"
sleep 1
echo "strobe: 300 mA, 200 ms"
echo 300000 | sudo tee $L/flash_brightness >/dev/null
echo 200000 | sudo tee $L/flash_timeout >/dev/null
echo 1 | sudo tee $L/flash_strobe >/dev/null
sleep 1
echo "fault: $(cat $L/flash_fault)"
