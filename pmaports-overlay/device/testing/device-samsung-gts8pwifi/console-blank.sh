#!/bin/sh
# console-blank: idle blanking for the VT console on the AMOLED panel.
#
# After BLANK_MIN minutes without input the console goes black: fbcon is
# unbound from the framebuffer (that stops the blinking cursor and any log
# line from painting) and the framebuffer is zeroed. On this panel an unlit
# pixel is an off pixel, so that is the burn-in protection; the panel and
# its rails stay powered and the DRM connector stays On. The next event on
# any input device (touch, pen, keys, keyboard) rebinds fbcon, which
# repaints the console.
#
# DPMS is deliberately not used: on 2026-09-22 a DPMS off (VT blank timer
# or panel-blank off) hung the tablet about a minute later and it reset
# itself, twice. Issue #41 tracks that. panel-blank off/on remains the
# manual DPMS tool for that investigation.
#
# Idle detection: every input device is opened once and kept open, so evdev
# queues its events for us (each open is its own client; the VT and getty
# see everything as before). Each poll drains what is queued with a short
# non-blocking read; any bytes at all mean activity. Devices that appear
# after start are picked up by `systemctl restart console-blank`.
#
# Setting: BLANK_MIN in /etc/conf.d/console-blank (0 disables, the daemon
# then exits). Edit the file, then `systemctl restart console-blank`.
# The kernel's own VT blank timer (consoleblank=) stays 0.

CONF=/etc/conf.d/console-blank
FB=/dev/fb0
POLL=2
READ_WINDOW=0.05

[ -r "$CONF" ] && . "$CONF"
BLANK_MIN=${BLANK_MIN:-10}

find_fbcon() {
	for v in /sys/class/vtconsole/vtcon*; do
		[ -r "$v/name" ] || continue
		case "$(cat "$v/name")" in
			*"frame buffer device"*) echo "$v"; return 0 ;;
		esac
	done
	return 1
}

# Open every /dev/input/event* on its own descriptor, 3 upwards.
FDS=""
open_inputs() {
	fd=3
	for d in /dev/input/event*; do
		[ -c "$d" ] || continue
		if eval "exec $fd<\"$d\""; then
			FDS="$FDS $fd"
			fd=$((fd + 1))
		fi
	done
	[ -n "$FDS" ]
}

# true when any watched device delivered events since the last poll;
# drains up to 64 KiB per device so a swipe does not count twice
input_seen() {
	seen=1
	for fd in $FDS; do
		n=$(eval "timeout $READ_WINDOW dd bs=65536 count=1 <&$fd" 2>/dev/null | wc -c)
		[ "$n" -gt 0 ] && seen=0
	done
	return $seen
}

console_on() {
	[ "$(cat "$VTCON/bind")" = "1" ]
}

blank() {
	echo 0 > "$VTCON/bind"
	# dd stops with ENOSPC at the end of the fixed-size mapping; expected
	dd if=/dev/zero of="$FB" bs=1M 2>/dev/null || true
}

unblank() {
	echo 1 > "$VTCON/bind"
}

status() {
	VTCON=$(find_fbcon) || { echo "no fbcon"; return 1; }
	echo "BLANK_MIN=$BLANK_MIN"
	console_on && echo "console: on" || echo "console: blanked"
	for c in /sys/class/drm/card*-DSI-*/dpms; do
		[ -r "$c" ] && echo "panel dpms: $(cat "$c")"
	done
}

run() {
	case "$BLANK_MIN" in
		''|*[!0-9]*) echo "console-blank: BLANK_MIN must be a number of minutes, got '$BLANK_MIN'" >&2; exit 1 ;;
	esac
	if [ "$BLANK_MIN" -eq 0 ]; then
		echo "console-blank: BLANK_MIN=0, blanking disabled"
		exit 0
	fi
	VTCON=$(find_fbcon) || { echo "console-blank: no framebuffer console" >&2; exit 1; }
	[ -c "$FB" ] || { echo "console-blank: $FB missing" >&2; exit 1; }
	open_inputs || { echo "console-blank: no input devices to watch" >&2; exit 1; }
	limit=$((BLANK_MIN * 60))
	idle=0
	echo "console-blank: blank after $BLANK_MIN min, watching $(echo $FDS | wc -w) input devices, polling every $POLL s"
	while :; do
		sleep "$POLL"
		if input_seen; then
			idle=0
			console_on || unblank
			continue
		fi
		idle=$((idle + POLL))
		if [ "$idle" -ge "$limit" ] && console_on; then
			blank
		fi
	done
}

case "${1:-run}" in
	run)     run ;;
	status)  status ;;
	off)     VTCON=$(find_fbcon) && blank ;;
	on)      VTCON=$(find_fbcon) && unblank ;;
	*)
		echo "usage: console-blank [run|status|off|on]" >&2
		exit 1
		;;
esac
