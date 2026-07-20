#!/bin/sh
# Manually blank/unblank the panel.
#
# Two very different worlds, one knob:
#
# NATIVE KMS (DRM_MSM + our S6TUUM1 panel driver): a blank is a real DPMS
# cycle — fbcon's FBIOBLANK reaches drm_fb_helper, the panel driver sends
# DCS display-off + sleep-in and drops the panel rail. True power-down,
# and unblank runs the full cold-init path (reset, init commands, PPS,
# display-on). This is the normal path now.
#
# LEGACY simpledrm (DRM_MSM=n, bootloader-initialized scanout): nothing in
# the kernel can talk to the panel, so FBIOBLANK is accepted and silently
# does nothing. On an AMOLED an unlit pixel is an off pixel, so the old
# trick still applies: unbind fbcon (kills the burn-in-prone blinking
# cursor), then zero the framebuffer. Rebinding repaints as the "unblank".
#
# Deliberately manual: no idle timer, invoked only on command.

set -e

FB=/dev/fb0

# Native panel driver present? The DSI connector only exists when our
# s6tuum1 driver bound under DRM_MSM; simpledrm exposes no connector for it.
find_dsi_conn() {
	for c in /sys/class/drm/card*-DSI-*; do
		[ -d "$c" ] || continue
		echo "$c"
		return 0
	done
	return 1
}

# Locate the framebuffer console binding (legacy path). Usually vtcon1, but
# the numbering depends on registration order — match on the name instead.
find_fbcon() {
	for v in /sys/class/vtconsole/vtcon*; do
		[ -r "$v/name" ] || continue
		case "$(cat "$v/name")" in
			*"frame buffer device"*) echo "$v"; return 0 ;;
		esac
	done
	return 1
}

DSI=$(find_dsi_conn || true)
VTCON=$(find_fbcon || true)

blank() {
	if [ -n "$DSI" ]; then
		# Real DPMS off: panel driver powers the DDIC down.
		echo 1 > /sys/class/graphics/fb0/blank
		return
	fi
	# Legacy: fbcon off first, then zero the emission.
	if [ -n "$VTCON" ]; then
		echo 0 > "$VTCON/bind"
	else
		echo "panel-blank: warning: no fbcon found, console may repaint" >&2
	fi
	# dd stops at ENOSPC on the last block, which is expected for a
	# fixed-size fbdev mapping — do not let it fail the set -e.
	dd if=/dev/zero of="$FB" bs=1M 2>/dev/null || true
}

unblank() {
	if [ -n "$DSI" ]; then
		# Real DPMS on: full panel cold init + repaint.
		echo 0 > /sys/class/graphics/fb0/blank
		return
	fi
	if [ -n "$VTCON" ]; then
		# Rebinding makes fbcon redraw the console from scratch.
		echo 1 > "$VTCON/bind"
	else
		echo "panel-blank: no fbcon to rebind" >&2
		return 1
	fi
}

status() {
	if [ -n "$DSI" ]; then
		# dpms reads "On"/"Off" — normalize to our vocabulary.
		case "$(cat "$DSI/dpms" 2>/dev/null)" in
			On)  echo "on" ;;
			Off) echo "blanked" ;;
			*)   echo "unknown" ;;
		esac
	elif [ -z "$VTCON" ]; then
		echo "unknown (no fbcon)"
	elif [ "$(cat "$VTCON/bind")" = "1" ]; then
		echo "on"
	else
		echo "blanked"
	fi
}

case "${1:-}" in
	on|unblank|wake)  unblank ;;
	off|blank)        blank ;;
	status)           status ;;
	toggle)
		if [ "$(status)" = "blanked" ]; then unblank; else blank; fi
		;;
	*)
		echo "usage: panel-blank {off|on|toggle|status}" >&2
		echo "  off     power the panel down (native) or zero the fb (legacy)" >&2
		echo "  on      power the panel back up / repaint the console" >&2
		exit 1
		;;
esac
