#!/bin/sh
# lens-test.sh: exercise the DW9808 lens and the module EEPROM on GENI I2C2 (kernel r29+).
# Usage: sh lens-test.sh check          # dmesg + media graph after boot
#        sh lens-test.sh lens [POS]     # standalone move, default 600, hold 3 s
#        sh lens-test.sh stream POS     # hold focus at POS, then 5 rear frames
#        sh lens-test.sh sweep [POS...] # 3 rear frames at each POS, default 0 150 300 400 600
#        sh lens-test.sh eeprom         # nvmem dump head
# The lens holds a position only while its subdev is open, so stream and sweep
# open it first and start the capture 3 s later. Frames land in $OUTDIR/rear-af$POS.raw;
# decode with tools/raw2png.py IN.raw 4128 3096 OUT.png.
# CAMTEST (default /home/user/camtest.sh) and OUTDIR (default /home/user) override the paths.
M="media-ctl -d /dev/media0"
CAMTEST=${CAMTEST:-/home/user/camtest.sh}
OUTDIR=${OUTDIR:-/home/user}
lens_sub() {
	LENS=$($M -p | sed -n 's/^- entity [0-9]*: \(dw9807 [0-9]*-000c\).*/\1/p')
	[ -n "$LENS" ] || { echo "!! no dw9807 lens entity in the media graph"; exit 1; }
	$M -e "$LENS"
}
# hold_capture POS COUNT: open the lens at POS, wait for it to settle, capture COUNT rear frames.
hold_capture() {
	v4l2-ctl -d $SUB --set-ctrl=focus_absolute=$1 --sleep 20 >/dev/null 2>&1 &
	sleep 3
	sh "$CAMTEST" rear $2 "$OUTDIR/rear-af$1.raw"
	wait
	ls -la "$OUTDIR/rear-af$1.raw"
}
case "${1:-check}" in
check)
	echo "== kernel: $(uname -r), apk: $(apk info linux-postmarketos-qcom-sm8450 2>/dev/null | head -1)"
	echo "== dmesg"; sudo dmesg | grep -E 'geni_i2c|988000|dw9807|dw9808|at24|hi1337|camss'
	echo "== media graph"; $M -p 2>/dev/null | grep -E '^- entity|dw9807|hi1337|ANCILLARY' || echo "!! no /dev/media0"
	echo "== video nodes: $(ls /dev/video* 2>/dev/null | wc -l)  nvmem: $(ls /sys/bus/nvmem/devices/ 2>/dev/null | tr '\n' ' ')"
	;;
lens)
	SUB=$(lens_sub); echo "lens subdev $SUB"
	v4l2-ctl -d $SUB --list-ctrls
	echo ">> moving to ${2:-600}, hold 3 s (listen for the click)"
	v4l2-ctl -d $SUB --set-ctrl=focus_absolute=${2:-600} --sleep 3
	sudo dmesg | grep -E 'dw9807|dw9808|geni_i2c' | tail -5
	;;
stream)
	POS=${2:?focus position}; SUB=$(lens_sub)
	hold_capture $POS 5
	;;
sweep)
	shift; SUB=$(lens_sub)
	for POS in ${*:-0 150 300 400 600}; do
		echo ">> focus $POS"
		hold_capture $POS 3
	done
	;;
eeprom)
	ls -la /sys/bus/nvmem/devices/
	for n in /sys/bus/nvmem/devices/*/nvmem; do echo "== $n"; sudo hexdump -C "$n" | head -24; echo "-- at 0x100"; sudo hexdump -C -s 256 -n 64 "$n"; done
	;;
*) echo "usage: sh lens-test.sh check|lens [POS]|stream POS|sweep [POS...]|eeprom"; exit 1 ;;
esac
