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
# CAMTEST (default: camtest.sh next to this script) and OUTDIR (default /home/user) override the paths.
M="media-ctl -d /dev/media0"
CAMTEST=${CAMTEST:-$(dirname "$0")/camtest.sh}
OUTDIR=${OUTDIR:-/home/user}
# lens_sub: set SUB to the lens subdev node, exit if the entity is missing.
lens_sub() {
	LENS=$($M -p | sed -n 's/^- entity [0-9]*: \(dw9807 [0-9]*-000c\).*/\1/p')
	[ -n "$LENS" ] || { echo "!! no dw9807 lens entity in the media graph"; exit 1; }
	SUB=$($M -e "$LENS")
	[ -n "$SUB" ] || { echo "!! media-ctl -e failed for $LENS"; exit 1; }
}
# need_camtest: stream and sweep capture through camtest.sh; fail before the lens is opened.
need_camtest() {
	[ -r "$CAMTEST" ] || { echo "!! $CAMTEST not found: set CAMTEST=/path/to/camtest.sh"; exit 1; }
}
# hold_capture POS COUNT: open the lens at POS, wait for it to settle, capture COUNT rear frames.
# The hold outlives camtest's own 30 s timeout and is killed once the frames are on disk.
# A rejected focus write (bad POS, driver error) exits v4l2-ctl at once; that is caught before capturing.
hold_capture() {
	case "$1" in ''|*[!0-9]*) echo "!! focus position must be an integer 0..1023, got '$1'"; return 1;; esac
	[ "$1" -le 1023 ] || { echo "!! focus position $1 out of range 0..1023"; return 1; }
	v4l2-ctl -d $SUB --set-ctrl=focus_absolute=$1 --sleep 120 >"$OUTDIR/.lens-hold.log" 2>&1 &
	HOLD=$!
	sleep 3
	kill -0 $HOLD 2>/dev/null || { echo "!! focus write to $1 failed:"; grep -v QUERYCAP "$OUTDIR/.lens-hold.log"; return 1; }
	sh "$CAMTEST" rear $2 "$OUTDIR/rear-af$1.raw"
	kill $HOLD 2>/dev/null; wait $HOLD 2>/dev/null
	rm -f "$OUTDIR/.lens-hold.log"
	ls -la "$OUTDIR/rear-af$1.raw"
}
case "${1:-check}" in
check)
	echo "== kernel: $(uname -r), apk: $(apk info linux-postmarketos-qcom-sm8450 2>/dev/null | head -1)"
	echo "== dmesg"; sudo dmesg | grep -E 'geni_i2c|988000|dw9807|dw9808|at24|hi1337|camss'
	echo "== media graph"
	if [ -e /dev/media0 ]; then $M -p | grep -E '^- entity|dw9807|hi1337' || echo "!! no entities listed"; else echo "!! no /dev/media0"; fi
	echo "== video nodes: $(ls /dev/video* 2>/dev/null | wc -l)  nvmem: $(ls /sys/bus/nvmem/devices/ 2>/dev/null | tr '\n' ' ')"
	;;
lens)
	lens_sub; echo "lens subdev $SUB"
	v4l2-ctl -d $SUB --list-ctrls 2>&1 | grep -v QUERYCAP
	echo ">> moving to ${2:-600}, hold 3 s (listen for the click)"
	v4l2-ctl -d $SUB --set-ctrl=focus_absolute=${2:-600} --sleep 3
	sudo dmesg | grep -E 'dw9807|dw9808|geni_i2c' | tail -5
	;;
stream)
	POS=${2:?focus position}; need_camtest; lens_sub
	hold_capture $POS 5
	;;
sweep)
	shift; need_camtest; lens_sub
	for POS in ${*:-0 150 300 400 600}; do
		echo ">> focus $POS"
		hold_capture $POS 3
	done
	;;
eeprom)
	ls -la /sys/bus/nvmem/devices/
	for n in /sys/bus/nvmem/devices/*/nvmem; do echo "== $n"; sudo hexdump -C "$n" | head -32; done
	;;
*) echo "usage: sh lens-test.sh check|lens [POS]|stream POS|sweep [POS...]|eeprom"; exit 1 ;;
esac
