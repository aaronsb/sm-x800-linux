#!/bin/sh
# Hold the pogo control pins at their STOCK levels and see whether the
# ~5 Hz oscillation on conn-detect stops. Run as root ON DEVICE.
#
# THEORY: gpio59 oscillates at ~95ms while the keyboard is attached (confirmed
# electrical, not contact bounce -- the user detached/reattached exactly once
# and we logged dozens of clean transitions). Meanwhile a full read-mode sweep
# of i2c-0 finds NOTHING at any address, all clean ENXIO NACKs, no geni errors.
# A live MCU that never ACKs, toggling a line at a steady ~10 transitions/sec,
# looks like a reset LOOP: boot -> fail -> reset, forever.
#
# We may be causing it. Stock pinctrl drives:
#     nrst  (gpio97) output-HIGH   <- MCU out of reset
#     swclk (gpio99) output-LOW    <- stock nrst_gpio/swclk_gpio states
# After our experiments 97 is an output at an unknown value and 99 is floating.
# A floating or mid-level nRST is exactly how you get a reset loop.
#
# Already ruled out, do not re-test:
#   pin mux (gpio68/69 = qup18)      bus health (clean ENXIO, no geni errors)
#   boot addr (0x51 hardcoded)       max77816 (display rail on this device)
#   full sweep 0x03-0x77 (empty)

CHIP=gpiochip3; BUS=0; EV=/dev/input/event2

hold() { gpioset -c "$CHIP" "$1=$2" >/dev/null 2>&1 </dev/null & echo $!; }
drop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

count_dock_events() {   # $1 = seconds to watch
	n=$(timeout "$1" evtest "$EV" 2>/dev/null | grep -c "SW_DOCK")
	echo "$n"
}

probe() {
	for a in 0x2a 0x51; do
		printf "    %s: " "$a"
		i2ctransfer -y -f "$BUS" "r1@$a" 2>&1 | head -1
	done
}

echo "=== BEFORE: oscillation rate with pins as we left them ==="
echo "  SW_DOCK events in 5s: $(count_dock_events 5)"

echo
echo "=== holding nrst=1 (out of reset) and swclk=0 (stock) ==="
PN=$(hold 97 1)
PS=$(hold 99 0)
sleep 3

echo "  SW_DOCK events in 5s while held: $(count_dock_events 5)"
echo "  (a large drop means WE were causing the reset loop)"

echo
echo "=== probe while held at stock levels ==="
probe
sleep 3
echo "  after 3s more:"
probe

echo
echo "=== also try with swclk left floating, nrst still high ==="
drop "$PS"
sleep 2
echo "  SW_DOCK events in 5s: $(count_dock_events 5)"
probe

drop "$PN"
echo
echo "=== done (lines released) ==="
