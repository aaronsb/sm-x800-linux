#!/bin/sh
# First-boot bring-up hook for gts8pwifi.
# The Samsung DECON framebuffer often comes up with a bpp/format that the
# console can't draw on until poked. The exact sysfs path is device-specific
# and not yet confirmed for gts8p -- fill in once the panel/decon node is known
# (compare gts8uwifi DTS 'decon' node). Until then this is a safe no-op.
for fb in /sys/class/graphics/fb0/bits_per_pixel; do
	[ -w "$fb" ] && echo 32 > "$fb" 2>/dev/null || true
done
