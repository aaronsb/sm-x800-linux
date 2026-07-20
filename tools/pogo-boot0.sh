#!/bin/sh
# Force the pogo STM32 into its ROM SYSTEM BOOTLOADER and probe 0x51.
# Run as root ON DEVICE.
#
# THE POINT: gpio99 ("stm32,mcu_swclk") is wired as BOOT0. Driving it HIGH
# across an nRST pulse makes the STM32 boot from ROM instead of application
# flash. The ROM bootloader ACKs at i2c 0x51 *regardless of whether the app
# firmware is healthy, corrupt, or absent*. Every test we ran until now held
# swclk LOW, which is the "run the app" configuration -- so we have never
# actually asked the silicon whether it is alive.
#
# THIS IS A CLEAN FORK:
#   0x51 ACKs  -> the MCU is powered and alive. Power is FINE. The fault is
#                 the application firmware or the attn handshake.
#   0x51 silent-> power/electrical. Software is out of road; get a scope.
#
# Sequence transcribed from stm32_sysboot_connect(), stm32_pogo_fw.c:399-436:
#     nrst=0 ; swclk(BOOT0)=1 ; delay 3ms ; nrst=1 ;
#     delay 50ms (STM32_BOOT_I2C_STARTUP_DELAY) ; swclk=0 ; send SYNC
# Stock repeats the whole pulse a second time if the first SYNC fails.
#
# The I2C bootloader sync byte is 0xFF (stm32_pogo_i2c.h:175). 0x7F is the
# USART bootloader -- different interface, do not use it here.
#
# gpioset only holds lines while its process lives, so we drive both pins from
# ONE interactive gpioset fed through a fifo. Killing/restarting between
# transitions would let nRST float at exactly the wrong moment.

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

# Start holding both lines at their stock "run" defaults first.
gpioset -c "$CHIP" -i "$NRST=1" "$BOOT0=0" < "$FIFO" >/dev/null 2>&1 &
GP=$!
exec 3> "$FIFO"
sleep 1
echo "=== holding nrst=1 boot0=0 (normal run state) ==="
gpioinfo 2>/dev/null | grep -iE "nrst|swclk"

probe51() {
	echo "  -- probing 0x51 (ROM bootloader) --"
	if out=$(i2ctransfer -y -f "$BUS" "r1@0x51" 2>&1); then
		echo "    ** 0x51 ACKed: $out **"
	else
		echo "    0x51 -> $out"
	fi
	echo "  -- SYNC 0xFF to 0x51 --"
	if out=$(i2ctransfer -y -f "$BUS" "w1@0x51" 0xff 2>&1); then
		echo "    ** SYNC ACCEPTED: $out **"
	else
		echo "    SYNC -> $out"
	fi
	echo "  -- 0x2a for comparison --"
	i2ctransfer -y -f "$BUS" "r1@0x2a" >/dev/null 2>&1 \
		&& echo "    ** 0x2a ACKed **" || echo "    0x2a silent"
}

echo
echo "=== baseline before BOOT0 (expect all silent) ==="
probe51

boot0_pulse() {
	echo "  nrst=0, boot0=1"
	echo "set $NRST=0" >&3
	echo "set $BOOT0=1" >&3
	usleep 3000            # 3ms, stock stm32_delay(3)
	echo "  nrst=1 (release, BOOT0 still high)"
	echo "set $NRST=1" >&3
	usleep 50000           # 50ms, STM32_BOOT_I2C_STARTUP_DELAY
	echo "  boot0=0"
	echo "set $BOOT0=0" >&3
	usleep 20000
}

echo
echo "=== BOOT0 PULSE #1 ==="
boot0_pulse
probe51

echo
echo "=== BOOT0 PULSE #2 (stock retries once) ==="
boot0_pulse
probe51

echo
echo "=== variant: hold BOOT0 HIGH through the probe ==="
# If the ROM only stays resident while BOOT0 is asserted, releasing it early
# would drop us back into the (broken) app before we ever get to ask.
echo "set $NRST=0" >&3
echo "set $BOOT0=1" >&3
usleep 3000
echo "set $NRST=1" >&3
usleep 50000
probe51

echo
echo "=== restoring nrst=1 boot0=0 ==="
echo "set $NRST=1" >&3
echo "set $BOOT0=0" >&3
sleep 1
echo "=== done ==="
