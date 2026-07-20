#!/bin/sh
# Isolate WHICH step of the STM32 I2C bootloader handshake fails. Run as root.
#
# Established: after a BOOT0 pulse, 0x51 answers a bare 1-byte read, and a
# 1-byte write is accepted. But a 2-byte command frame [cmd, ~cmd] returns
# ETIMEDOUT. The STM32 bootloader clock-stretches while it processes a command;
# the geni controller may be timing out on that stretch, or the frame may need
# to be a single combined transaction rather than write-STOP-read.
#
# This tries the same GET command several ways and reports each outcome, so we
# can tell a protocol framing problem from a controller limitation.
#
# READ ONLY.

CHIP=gpiochip3; NRST=97; BOOT0=99; BUS=0
FIFO=/tmp/pogo-gpio.fifo

cleanup() {
	[ -n "$GP" ] && kill "$GP" 2>/dev/null
	exec 3>&- 2>/dev/null
	rm -f "$FIFO"
}
trap cleanup EXIT INT TERM

for p in $(pgrep -x gpioset 2>/dev/null); do kill "$p" 2>/dev/null; done
sleep 1
rm -f "$FIFO"; mkfifo "$FIFO" || exit 1
gpioset -c "$CHIP" -i "$NRST=1" "$BOOT0=0" < "$FIFO" >/dev/null 2>&1 &
GP=$!
exec 3> "$FIFO"
sleep 1

pulse() {
	echo "set $NRST=0"  >&3
	echo "set $BOOT0=1" >&3
	usleep 3000
	echo "set $NRST=1"  >&3
	usleep 50000
	# BOOT0 stays HIGH so the ROM remains resident through the probe.
}

try() {   # $1 = label, rest = i2ctransfer args
	lbl=$1; shift
	printf "  %-42s " "$lbl"
	out=$(i2ctransfer -y -f "$BUS" "$@" 2>&1)
	rc=$?
	if [ $rc -eq 0 ]; then echo "OK  -> ${out:-<no data>}"; else echo "FAIL-> $out"; fi
}

echo "=== pulse into ROM bootloader ==="
pulse

echo
echo "=== A. baseline reads/writes that we know worked ==="
try "r1 (bare read)"                       r1@0x51
try "w1 0xff (single-byte write)"          w1@0x51 0xff

echo
echo "=== B. GET command frame, separate write then read ==="
try "w2 0x00 0xff"                         w2@0x51 0x00 0xff
try "r1 (status after GET)"                r1@0x51

echo
echo "=== C. GET as ONE combined transaction (repeated start) ==="
pulse
try "w2 0x00 0xff + r1"                    w2@0x51 0x00 0xff r1@0x51

echo
echo "=== D. does a 2-byte write work at all? try other command frames ==="
pulse
try "GET-ID   w2 0x02 0xfd"                w2@0x51 0x02 0xfd
try "r1 status"                            r1@0x51
pulse
try "GET-VER  w2 0x01 0xfe"                w2@0x51 0x01 0xfe
try "r1 status"                            r1@0x51

echo
echo "=== E. two single-byte writes instead of one 2-byte write ==="
pulse
try "w1 0x00"                              w1@0x51 0x00
try "w1 0xff"                              w1@0x51 0xff
try "r1 status"                            r1@0x51

echo
echo "=== F. multi-byte read (is reading >1 byte the problem?) ==="
pulse
try "r2"                                   r2@0x51
try "r4"                                   r4@0x51

echo
echo "=== bus errors logged during this run ==="
dmesg | grep -iE "geni|i2c" | tail -8

echo
echo "=== restoring run state ==="
echo "set $BOOT0=0" >&3
echo "set $NRST=0"  >&3
usleep 3000
echo "set $NRST=1"  >&3
sleep 1
echo "=== done ==="
