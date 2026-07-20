#!/bin/sh
# Pogo Book Cover Keyboard (STM32 @ i2c 0x2a) bring-up diagnostics.
#
# Run ON THE DEVICE over ssh. Read-only by default; pass --pulse-nrst to
# actually toggle the MCU reset line, or --power-cycle to bounce its rail.
#
#   scp tools/pogo-diag.sh user@<ip>:/tmp/ && ssh user@<ip> 'sudo sh /tmp/pogo-diag.sh'
#
# Context: the keyboard WAS physically attached during the scans that found
# nothing at 0x2a/0x51, so "no accessory present" is ruled out. This checks
# the four remaining suspects. See the &i2c18 comment in the DTS.
#
# Hardware facts, all confirmed from the stock DTB:
#   i2c addr 0x2a on i2c@88c000 (mainline i2c18, shows up as i2c-0)
#   tlmm gpio59 conn-detect   tlmm gpio70 VDDO enable
#   tlmm gpio71 attn/irq      tlmm gpio97 nRST     tlmm gpio99 swclk
#   tlmm gpio68/69 = i2c18 SDA/SCL

PULSE=0
POWER_CYCLE=0
for a in "$@"; do
	case "$a" in
		--pulse-nrst)  PULSE=1 ;;
		--power-cycle) POWER_CYCLE=1 ;;
		*) echo "usage: $0 [--pulse-nrst] [--power-cycle]" >&2; exit 1 ;;
	esac
done

hdr() { echo; echo "=== $* ==="; }

hdr "1. i2c controllers"
# Which /dev/i2c-N is the pogo bus? Match the 88c000 address, do not assume 0.
BUS=""
for d in /sys/bus/i2c/devices/i2c-*; do
	[ -e "$d/name" ] || continue
	n=$(basename "$d"); nm=$(cat "$d/name")
	echo "  $n : $nm"
	case "$nm" in *88c000*) BUS="${n#i2c-}" ;; esac
done
if [ -n "$BUS" ]; then
	echo "  -> pogo bus is i2c-$BUS (88c000 == stock qupv3_se18_i2c)"
else
	echo "  !! no controller matching 88c000 — i2c18 did not register"
fi

hdr "2. pin mux (suspect: SDA/SCL not muxed to QUP)"
# If gpio68/69 are still 'gpio' rather than a qup function, the controller
# registers happily and drives nothing at all.
PMX=$(ls /sys/kernel/debug/pinctrl/*tlmm*/pinmux-pins 2>/dev/null | head -1)
if [ -n "$PMX" ]; then
	grep -E "pin (59|68|69|70|71|97|99)\b" "$PMX" || echo "  (no matching pins)"
else
	echo "  !! no tlmm pinmux-pins in debugfs — is tlmm probed? see section 3"
fi

hdr "3. gpio chips (earlier finding: tlmm absent from debugfs)"
for c in /sys/bus/gpio/devices/gpiochip*; do
	[ -e "$c" ] || continue
	lbl=$(cat "$c/label" 2>/dev/null)
	n=$(cat "$c/ngpio" 2>/dev/null)
	echo "  $(basename "$c") label=$lbl ngpio=$n"
done
command -v gpioinfo >/dev/null && gpioinfo 2>/dev/null | grep -iE "pogo|tlmm|^gpiochip" | head -20

hdr "4. pogo rail state"
grep -i pogo /sys/kernel/debug/regulator/regulator_summary 2>/dev/null \
	|| echo "  (regulator_summary unavailable)"

hdr "5. conn-detect as an input switch"
# gpio59 is exposed as EV_SW/SW_DOCK. SW_DOCK is bit 5 of the SW bitmap.
for e in /sys/class/input/event*; do
	dev=$(basename "$e")
	nm=$(cat "/sys/class/input/$dev/device/name" 2>/dev/null)
	case "$nm" in
		*[Pp]ogo*|*gpio-keys*)
			echo "  $dev : $nm"
			sw=$(cat "/sys/class/input/$dev/device/capabilities/sw" 2>/dev/null)
			echo "    sw capability bitmap: ${sw:-none}"
			;;
	esac
done
echo "  (run 'evtest' and attach/detach the cover to watch SW_DOCK toggle)"

[ -z "$BUS" ] && { echo; echo "No pogo bus — stopping."; exit 1; }

scan() {
	echo "  --- $1 ---"
	# -r = READ-mode probe. Plain i2cdetect uses SMBus Quick Write, which the
	# geni controller does not implement, so it SKIPS most addresses INCLUDING
	# 0x2a and reports a misleading empty grid. Always -r on this hardware.
	i2cdetect -y -r "$BUS" 2>&1 | sed 's/^/    /'
	for addr in 0x2a 0x51; do
		if i2cget -y "$BUS" "$addr" 0x00 b >/dev/null 2>&1; then
			echo "    ** $addr ACKed a read **"
		else
			echo "    $addr silent"
		fi
	done
}

hdr "6. i2c scan on i2c-$BUS (READ mode)"
scan "baseline"

if [ "$POWER_CYCLE" = "1" ]; then
	hdr "7. VDDO power cycle"
	# The rail is regulator-always-on in our DTS, so there is no consumer to
	# disable it through — drive the enable pin (gpio70) directly instead.
	if command -v gpioset >/dev/null && command -v gpiofind >/dev/null; then
		L=$(gpiofind pogo-vddo-en) || { echo "  !! pogo-vddo-en not found"; L=""; }
		if [ -n "$L" ]; then
			# shellcheck disable=SC2086
			gpioset $(echo "$L" | cut -d' ' -f1) $(echo "$L" | cut -d' ' -f2)=0
			sleep 1
			# shellcheck disable=SC2086
			gpioset $(echo "$L" | cut -d' ' -f1) $(echo "$L" | cut -d' ' -f2)=1
			sleep 1
			scan "after VDDO power cycle"
		fi
	else
		echo "  !! libgpiod (gpioset/gpiofind) not installed"
	fi
fi

if [ "$PULSE" = "1" ]; then
	hdr "8. nRST pulse"
	# THE headline experiment. Downstream toggles nrst rather than holding it;
	# a wedged MCU needs a real reset edge. This only works because gpio97 is
	# no longer a gpio-hog (a hog would give -EBUSY here).
	if command -v gpioset >/dev/null && command -v gpiofind >/dev/null; then
		L=$(gpiofind pogo-stm32-nrst) || { echo "  !! pogo-stm32-nrst not found"; L=""; }
		if [ -n "$L" ]; then
			CHIP=$(echo "$L" | cut -d' ' -f1); LINE=$(echo "$L" | cut -d' ' -f2)
			echo "  pulsing $CHIP line $LINE low->high"
			gpioset "$CHIP" "$LINE"=0
			sleep 1
			gpioset "$CHIP" "$LINE"=1
			sleep 1
			scan "after nRST pulse"
		fi
	else
		echo "  !! libgpiod (gpioset/gpiofind) not installed — apk add libgpiod"
	fi
fi

hdr "kernel messages"
dmesg | grep -iE "i2c|geni|qup|tlmm|pinctrl|stm32|pogo" | tail -25

echo
echo "Done. If 0x2a is still silent after both a reset pulse and a power"
echo "cycle, and gpio68/69 are correctly muxed, the next step is a scope or"
echo "logic analyser on the pogo pins — software has run out of road."
