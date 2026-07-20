#!/bin/sh
# Manually blank/unblank the panel to protect the OLED from burn-in.
#
# WHY THIS IS NOT `echo 1 > /sys/class/graphics/fb0/blank`:
#
# We build with DRM_MSM=n and let simpledrm own the panel (see docs/05). That
# means there is no DSI driver and no backlight driver — the display block is
# still in whatever state the bootloader left it, continuously scanning out
# the framebuffer at 0xb8000000. Nothing in this kernel can tell the panel to
# power down. simpledrm has no meaningful blank hook, so the sysfs write is
# accepted and silently does nothing to the hardware.
#
# On an AMOLED that is fine: a black pixel is an unlit pixel. Zeroing the
# framebuffer genuinely stops the emission, which is exactly what burn-in
# protection needs.
#
# The catch is fbcon. If it stays bound it repaints the console — and the
# blinking cursor sitting at one fixed cell is itself a burn-in risk. So we
# unbind fbcon FIRST (the VT falls back to dummycon), THEN zero the memory.
# Rebinding triggers a full repaint, which is our "unblank".
#
# Deliberately manual: no idle timer, invoked only on command.

set -e

FB=/dev/fb0

# Locate the framebuffer console binding. It is usually vtcon1, but the
# numbering depends on registration order — match on the name instead.
find_fbcon() {
	for v in /sys/class/vtconsole/vtcon*; do
		[ -r "$v/name" ] || continue
		case "$(cat "$v/name")" in
			*"frame buffer device"*) echo "$v"; return 0 ;;
		esac
	done
	return 1
}

VTCON=$(find_fbcon || true)

blank() {
	if [ -n "$VTCON" ]; then
		echo 0 > "$VTCON/bind"
	else
		echo "panel-blank: warning: no fbcon found, console may repaint" >&2
	fi
	# Zero the whole framebuffer. dd stops at ENOSPC on the last block, which
	# is expected for a fixed-size fbdev mapping — do not let it fail the set -e.
	dd if=/dev/zero of="$FB" bs=1M 2>/dev/null || true
}

unblank() {
	if [ -n "$VTCON" ]; then
		# Rebinding makes fbcon redraw the console from scratch.
		echo 1 > "$VTCON/bind"
	else
		echo "panel-blank: no fbcon to rebind" >&2
		return 1
	fi
}

status() {
	if [ -z "$VTCON" ]; then
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
		echo "  off     zero the framebuffer and unbind fbcon (OLED goes dark)" >&2
		echo "  on      rebind fbcon and repaint the console" >&2
		exit 1
		;;
esac
