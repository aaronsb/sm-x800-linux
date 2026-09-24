#!/bin/sh
# gts8pwifi-usb-gadget: the tablet as a USB device to a PC.
#
# One configfs gadget with three functions: NCM ethernet (usb0; the host
# sees a cdc_ncm interface), ACM serial (/dev/ttyGS0; the host sees
# /dev/ttyACM*) and MTP (FunctionFS served by umtprd; the host's file
# manager sees a media device, /etc/umtprd/umtprd.conf lists what it
# shows). The USB IDs are postmarketOS's (18d1:d001), so hosts that
# know pmOS devices treat it as one.
#
# The gadget is bound to the UDC once and stays bound. The Type-C driver
# (max77705-usbc, ADR-003) switches dwc3 between host and device by cable:
# a PC attaching as source makes the tablet the device and the gadget
# enumerates; a USB device attaching makes the tablet the host.
#
# Addresses: usb0 gets 172.16.42.1/24 here (NetworkManager leaves gadget
# interfaces unmanaged by its own udev rule), unudhcpd@usb0 hands the PC
# 172.16.42.2, and serial-getty@ttyGS0 gives a login on the serial
# function.

GADGETS=/sys/kernel/config/usb_gadget
G=$GADGETS/gts8pwifi
ADDR=172.16.42.1/24
FFS=/dev/mtp

# Unbind a gadget and remove it: config links, configs, functions, strings.
remove() {
	g=$1
	echo "" > "$g/UDC" 2>/dev/null || true
	for c in "$g"/configs/*; do
		[ -d "$c" ] || continue
		for l in "$c"/*; do
			[ -L "$l" ] && rm -f "$l"
		done
		rmdir "$c"/strings/* 2>/dev/null
		rmdir "$c"
	done
	for f in "$g"/functions/*; do
		[ -d "$f" ] && rmdir "$f"
	done
	rmdir "$g"/strings/* 2>/dev/null
	rmdir "$g"
}

start() {
	udc=$(ls /sys/class/udc 2>/dev/null | head -n1)
	[ -n "$udc" ] || { echo "gts8pwifi-usb-gadget: no UDC" >&2; exit 1; }

	# postmarketOS's initramfs leaves its own gadget (g1, NCM only, for
	# early-boot debugging) bound to the UDC; take the UDC over.
	for g in "$GADGETS"/*; do
		[ -d "$g" ] && [ "$g" != "$G" ] || continue
		echo "gts8pwifi-usb-gadget: removing $(basename "$g")"
		remove "$g"
	done

	if [ -d "$G" ]; then
		if [ -z "$(cat "$G/UDC")" ]; then
			mtp_up
			echo "$udc" > "$G/UDC"
		fi
		net_up
		return 0
	fi

	mkdir -p "$G"
	echo 0x18d1 > "$G/idVendor"
	echo 0xd001 > "$G/idProduct"
	echo 0x0200 > "$G/bcdUSB"

	mkdir -p "$G/strings/0x409"
	echo postmarketOS > "$G/strings/0x409/manufacturer"
	echo "Galaxy Tab S8+" > "$G/strings/0x409/product"
	cut -c1-16 /etc/machine-id > "$G/strings/0x409/serialnumber"

	mkdir -p "$G/functions/ncm.usb0" "$G/functions/acm.GS0" \
		"$G/functions/ffs.mtp"
	mkdir -p "$G/configs/c.1/strings/0x409"
	echo "NCM + ACM + MTP" > "$G/configs/c.1/strings/0x409/configuration"
	echo 500 > "$G/configs/c.1/MaxPower"
	ln -s "$G/functions/ncm.usb0" "$G/configs/c.1/"
	ln -s "$G/functions/acm.GS0" "$G/configs/c.1/"
	ln -s "$G/functions/ffs.mtp" "$G/configs/c.1/"

	mtp_up
	echo "$udc" > "$G/UDC"
	net_up
}

# A FunctionFS function can be bound only after its daemon has written the
# descriptors, which makes the endpoint files appear. Without MTP the
# gadget still comes up with NCM and ACM.
mtp_up() {
	mkdir -p "$FFS"
	mountpoint -q "$FFS" || mount -t functionfs mtp "$FFS"
	systemctl --no-block restart umtprd.service
	i=0
	while [ ! -e "$FFS/ep1" ] && [ $i -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	if [ ! -e "$FFS/ep1" ]; then
		echo "gts8pwifi-usb-gadget: umtprd did not start, MTP left out" >&2
		rm -f "$G/configs/c.1/ffs.mtp"
	fi
}

# The NCM interface exists once the gadget is bound.
net_up() {
	ifname=$(cat "$G/functions/ncm.usb0/ifname")
	ip addr flush dev "$ifname"
	ip addr add "$ADDR" dev "$ifname"
	ip link set "$ifname" up
}

stop() {
	[ -d "$G" ] || return 0
	echo "" > "$G/UDC" 2>/dev/null || true
	systemctl stop umtprd.service
	mountpoint -q "$FFS" && umount "$FFS"
	remove "$G"
}

case "$1" in
	start) start ;;
	stop) stop ;;
	*) echo "usage: gts8pwifi-usb-gadget start|stop" >&2; exit 1 ;;
esac
