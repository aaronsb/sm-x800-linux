#!/bin/sh
# Is the i2c18 bus physically wired up, and is anything alive on the pogo pins?
# Run as root ON THE DEVICE.
#
# The controller registering as i2c-0 (Geni-I2C) proves only that the DRIVER
# probed. If tlmm gpio68/69 are still muxed as plain "gpio" rather than the
# QUP function, the controller happily clocks out transfers that never reach
# a physical pin, and every address reads silent -- exactly what we see.
#
# Stock pinctrl for reference (from stock-fdt.dtb):
#   qup_i2c18_data_clk -> gpio68 (SDA), gpio69 (SCL), function "qup..."
#   nrst_gpio  gpio97 output-high     conn_irq gpio59 input, bias-disable
#   attn_irq   gpio71 input           swclk    gpio99 output-low

echo "=== pinmux for the pins that matter ==="
# Find the tlmm pinctrl dir without using a glob that needs expansion twice.
for d in /sys/kernel/debug/pinctrl/*; do
	[ -f "$d/pinmux-pins" ] || continue
	case "$(basename "$d")" in
		*f100000*|*pinctrl*)
			echo "  [$(basename "$d")]"
			grep -E "pin (59|68|69|70|71|97|99)\b" "$d/pinmux-pins" 2>/dev/null \
				| sed 's/^/    /'
			;;
	esac
done

echo
echo "=== what owns those pins (pinctrl-handles) ==="
for d in /sys/kernel/debug/pinctrl/*; do
	[ -f "$d/pinconf-groups" ] || continue
	grep -iE "gpio(68|69)" "$d/pinconf-groups" 2>/dev/null | head -5 | sed 's/^/    /'
done

echo
echo "=== i2c adapter ==="
for a in /sys/bus/i2c/devices/i2c-*; do
	echo "  $(basename "$a") name=$(cat "$a/name" 2>/dev/null)"
done
echo "  i2c-0 device dir:"
ls /sys/bus/i2c/devices/i2c-0/device 2>/dev/null | head -5 | sed 's/^/    /'

echo
echo "=== does the controller report transfer errors? ==="
# A bus with no pull-ups / unmuxed pins usually logs arbitration or NACK
# errors rather than timing out silently.
dmesg | grep -iE "geni|i2c|qup" | tail -20

echo
echo "=== single transfer attempt with error text ==="
i2ctransfer -y -f 0 r1@0x2a 2>&1 | sed 's/^/    /'
i2cget -y -f 0 0x2a 2>&1 | sed 's/^/    /'

echo
echo "=== conn-detect: read via the input layer ==="
# gpio59 is held by gpio-keys so gpioget cannot read it; ask evtest instead.
for e in /dev/input/event*; do
	n=$(cat "/sys/class/input/$(basename "$e")/device/name" 2>/dev/null)
	case "$n" in
		gpio-keys)
			evtest --query "$e" EV_SW 5
			echo "    SW_DOCK on $e: exit=$? (0=undocked, 10=docked)"
			;;
	esac
done
echo "=== done ==="
