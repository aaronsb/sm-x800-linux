#!/bin/sh
# vbus-otg — switch tablet-sourced USB VBUS (MAX77705 OTG 5V boost).
#
#   vbus-otg on       source 5V so bus-powered USB devices work in host mode
#   vbus-otg off      stop sourcing VBUS
#   vbus-otg [status] show current state
#
# "on" fails with EBUSY while a charger input is present — the boost drives
# the same pins the charger feeds from, and the driver refuses the
# contention. Unplug the charger first.
#
# Kernel side: samsung,max77705-otg regulator + regulator-output node in the
# DTS; see docs/07 and max77705-otg.c in the kernel package.

STATE=/sys/devices/platform/vbus-otg/state

if [ ! -f "$STATE" ]; then
	echo "vbus-otg: $STATE not found (driver not probed?)" >&2
	exit 1
fi

case "${1:-status}" in
on)
	echo enabled > "$STATE" || exit 1
	;;
off)
	echo disabled > "$STATE" || exit 1
	;;
status)
	cat "$STATE"
	;;
*)
	echo "usage: vbus-otg [on|off|status]" >&2
	exit 1
	;;
esac
