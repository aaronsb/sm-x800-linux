/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Samsung Galaxy Tab S8+ Wi-Fi (SM-X800), codename "gts8pwifi".
 * SM8450 (Waipio). Derived from board-r0q.c (Galaxy S22, same SoC).
 *
 * The Samsung bootloader leaves the panel scanning the cont_splash
 * framebuffer, so simplefb here gives uniLoader (and then the kernel)
 * a visible console on the panel.
 *
 * Geometry comes from the stock DTB:
 *   splash reserved-memory = <0x0 0xb8000000 0x0 0x2b00000> (45 MiB)
 *
 * Scanout is LANDSCAPE 2800x1752. The stock DTB's physical panel size is
 * 267 mm x 167 mm (qcom,mdss-pan-physical-{width,height}-dimension =
 * 0x10b/0xa7), ratio 1.60 == 2800/1752, so the long axis is the scanline.
 * Do NOT use the touch controller's sec,max_coords = <0x6d8 0xaf0>
 * (1752x2800) — that is the touchscreen's portrait coordinate space, not
 * the display scanout. Getting this backwards renders correctly-sized but
 * diagonally sheared text (each row offset by 2800-1752 px).
 */

#include <board.h>
#include <util.h>
#include <drivers/framework.h>
#include <lib/simplefb.h>

static struct video_info gts8pwifi_fb = {
	.format = FB_FORMAT_ARGB8888,
	.width = 2800,
	.height = 1752,
	.stride = 4,
	.address = (void *)0xb8000000
};

static const struct device gts8pwifi_devices[] = {
	{ "simplefb", &gts8pwifi_fb, "fb" },
};

struct board_data board_ops = {
	.name = "samsung-gts8pwifi",
	.ops = {
	},
	.devices = gts8pwifi_devices,
	.num_devices = ARRAY_SIZE(gts8pwifi_devices),
	.quirks = 0
};
