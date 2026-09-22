#!/bin/sh
# console-blank: display policy for the VT console on the AMOLED panel.
#
# Idle: after BLANK_MIN minutes without input the console goes black: fbcon
# is unbound from the framebuffer (that stops the blinking cursor and any
# log line from painting) and the framebuffer is zeroed. On this panel an
# unlit pixel is an off pixel, so that is the burn-in protection; the panel
# and its rails stay powered and the DRM connector stays On. The next event
# on any input device (touch, pen, keys, keyboard) rebinds fbcon, which
# repaints the console.
#
# Lid: the folio-state daemon (foliod, ADR-002) publishes SW_LID on a
# virtual input device named "folio-state". While it reads closed the
# console is blanked and no input brings it back, the power button
# included. When it returns to open the console comes back and the idle
# count restarts. Without the device the idle policy alone applies.
# Input arriving while the lid reads closed is what the operator does on
# opening (a hall edge, a touch), so it is forwarded to foliod as SIGUSR1,
# which samples the magnetometer at once instead of at its next heartbeat.
#
# Power button: with the lid open, bytes on the pmic_pwrkey device toggle
# the console, blank if visible and visible if blanked. Every other device
# counts as activity. logind ignores the key (HandlePowerKey=ignore).
#
# DPMS is deliberately not used: on 2026-09-22 a DPMS off (VT blank timer
# or panel-blank off) hung the tablet about a minute later and it reset
# itself, twice. Issue #41 tracks that. panel-blank off/on remains the
# manual DPMS tool for that investigation.
#
# Idle detection: every input device is opened once and kept open, so evdev
# queues its events for us (each open is its own client; the VT and getty
# see everything as before). Each poll drains what is queued with a short
# non-blocking read; any bytes at all mean activity. When the number of
# event nodes changes the descriptors are closed and reopened, so a device
# that appears late (the headset jack, a USB keyboard, a foliod restart) is
# picked up on the next poll. The folio-state device is queried, not held.
#
# Setting: BLANK_MIN in /etc/conf.d/console-blank (0 disables, the daemon
# then exits). Edit the file, then `systemctl restart console-blank`.
# The kernel's own VT blank timer (consoleblank=) stays 0.

CONF=/etc/conf.d/console-blank
FB=/dev/fb0
POLL=2
READ_WINDOW=0.05
FOLIO_NAME=folio-state
PWRKEY_NAME=pmic_pwrkey

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

# kernel name of an event node
input_name() {
	cat "/sys/class/input/${1##*/}/device/name" 2>/dev/null
}

count_inputs() {
	n=0
	for d in /dev/input/event*; do
		[ -c "$d" ] && n=$((n + 1))
	done
	echo "$n"
}

# Open every /dev/input/event* on its own descriptor, 3 upwards. The
# folio-state node is remembered in FOLIO and not held; the power key's
# descriptor is remembered in PWR_FD.
FDS=""
PWR_FD=""
FOLIO=""
COUNT=0
open_inputs() {
	FDS=""
	PWR_FD=""
	FOLIO=""
	COUNT=$(count_inputs)
	fd=3
	for d in /dev/input/event*; do
		[ -c "$d" ] || continue
		name=$(input_name "$d")
		if [ "$name" = "$FOLIO_NAME" ]; then
			FOLIO=$d
			continue
		fi
		if eval "exec $fd<\"$d\""; then
			[ "$name" = "$PWRKEY_NAME" ] && PWR_FD=$fd
			FDS="$FDS $fd"
			fd=$((fd + 1))
		fi
	done
	[ -n "$FDS" ]
}

close_inputs() {
	for fd in $FDS; do
		eval "exec $fd<&-"
	done
	FDS=""
	PWR_FD=""
}

# reopen everything when the number of event nodes changed
rescan_inputs() {
	[ "$(count_inputs)" -eq "$COUNT" ] && return 0
	close_inputs
	open_inputs || { echo "console-blank: no input devices to watch" >&2; exit 1; }
	echo "console-blank: rescanned, watching $(echo $FDS | wc -w) input devices, folio-state ${FOLIO:-absent}"
}

# bytes queued on one descriptor since the last poll; drains up to 64 KiB
# so a swipe does not count twice
drain() {
	eval "timeout $READ_WINDOW dd bs=65536 count=1 <&$1" 2>/dev/null | wc -c
}

# ACTIVITY=0 when any device other than the power key delivered events
# since the last poll; POWER=0 when the power key did
poll_inputs() {
	ACTIVITY=1
	POWER=1
	for fd in $FDS; do
		n=$(drain "$fd")
		[ "$n" -gt 0 ] || continue
		if [ "$fd" = "$PWR_FD" ]; then
			POWER=0
		else
			ACTIVITY=0
		fi
	done
}

# ask foliod for a sample now; it decides what the lid is
kick_foliod() {
	pid=$(systemctl show -p MainPID --value folio-state 2>/dev/null)
	[ -n "$pid" ] && [ "$pid" != 0 ] && kill -USR1 "$pid" 2>/dev/null
}

# open, closed, or none when there is no folio-state device
lid_state() {
	if [ -z "$FOLIO" ] || [ ! -c "$FOLIO" ]; then
		echo none
		return
	fi
	evtest --query "$FOLIO" EV_SW SW_LID >/dev/null 2>&1
	case $? in
		0) echo open ;;
		10) echo closed ;;
		*) echo none ;;
	esac
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
	for d in /dev/input/event*; do
		[ "$(input_name "$d")" = "$FOLIO_NAME" ] && FOLIO=$d
	done
	echo "lid: $(lid_state)${FOLIO:+ ($FOLIO)}"
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
	lid=open
	echo "console-blank: blank after $BLANK_MIN min, watching $(echo $FDS | wc -w) input devices, polling every $POLL s, folio-state ${FOLIO:-absent}"
	while :; do
		sleep "$POLL"
		rescan_inputs
		prev=$lid
		lid=$(lid_state)
		if [ "$lid" = closed ]; then
			# folio closed: dark, and nothing typed or pressed brings it
			# back; foliod is told there was input so it re-checks the lid
			poll_inputs
			console_on && blank
			[ "$ACTIVITY" -eq 0 ] || [ "$POWER" -eq 0 ] && kick_foliod
			idle=0
			continue
		fi
		if [ "$prev" = closed ]; then
			# folio opened: light up, discard what arrived while closed
			poll_inputs
			console_on || unblank
			idle=0
			continue
		fi
		poll_inputs
		if [ "$POWER" -eq 0 ]; then
			if console_on; then blank; else unblank; fi
			idle=0
			continue
		fi
		if [ "$ACTIVITY" -eq 0 ]; then
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
