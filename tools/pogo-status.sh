#!/bin/sh
# Quick pogo state readout. Run as root ON DEVICE. READ ONLY.
EV=/dev/input/event2; CHIP=gpiochip3; BUS=0
evtest --query "$EV" EV_SW 5
[ $? -eq 10 ] && DOCK=DOCKED || DOCK=UNDOCKED
echo "  SW_DOCK        : $DOCK"
echo "  conn edges/5s  : $(timeout 5 evtest "$EV" 2>/dev/null | grep -c SW_DOCK)"
echo "  attn (gpio71)  : $(gpioget -c $CHIP 71 2>&1)"
echo "  swclk (gpio99) : $(gpioget -c $CHIP 99 2>&1)"
echo "  nrst (gpio97)  : $(gpioget -c $CHIP 97 2>&1)"
echo "  vddo rail      : $(grep -i pogo /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | awk '{print $1, $2}')"
printf "  0x2a           : "
i2ctransfer -y -f "$BUS" r1@0x2a >/dev/null 2>&1 && echo "ACK" || echo "silent"
