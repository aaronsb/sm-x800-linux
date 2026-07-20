// SPDX-License-Identifier: GPL-2.0-only
/*
 * Samsung S6TUUM1 AMSA24VU01 WQXGA AMOLED panel (Galaxy Tab S8+, SM-X800).
 *
 * 2800x1752 landscape raster, DSI command mode, 4 lanes, DSC 1.1
 * (8 bpp, two 1400x12 slices per line). Init sequence, DSC parameters and
 * power/reset facts extracted from the stock DTB's ss_dsi_panel node and
 * the downstream techpack driver — see device-facts/display-s6tuum1.md
 * for the full derivation.
 *
 * Modeled on panel-samsung-s6e3ha8.c (same tree). The PPS is built by
 * drm_dsc_pps_payload_pack() from drm_dsc_config rather than replaying
 * the stock 0x9E byte stream; decoded fields match the stock PPS.
 *
 * Only the 120 Hz timing is implemented (DDIC reg 0x60 = 0x20; stock also
 * has a 60 Hz variant with 0x60 = 0x00 for VRR — later work).
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>

#include <drm/display/drm_dsc.h>
#include <drm/display/drm_dsc_helper.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_panel.h>

struct s6tuum1 {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct drm_dsc_config dsc;
	struct gpio_desc *reset_gpio;
	struct regulator *vdd;
};

static inline struct s6tuum1 *to_s6tuum1(struct drm_panel *panel)
{
	return container_of(panel, struct s6tuum1, panel);
}

static void s6tuum1_reset(struct s6tuum1 *priv)
{
	gpiod_set_value_cansleep(priv->reset_gpio, 1);
	usleep_range(5000, 6000);
	gpiod_set_value_cansleep(priv->reset_gpio, 0);
	usleep_range(5000, 6000);
	gpiod_set_value_cansleep(priv->reset_gpio, 1);
	usleep_range(10000, 11000);
}

/*
 * Stock qcom,mdss-dsi-on-command, in order. Register meanings are the
 * DDIC's own; the visible landmarks are 0x60 = refresh rate select and
 * the 0xB0 global-parameter pointer writes.
 */
static int s6tuum1_on(struct s6tuum1 *priv)
{
	struct mipi_dsi_multi_context ctx = { .dsi = priv->dsi };
	struct drm_dsc_picture_parameter_set pps;

	priv->dsi->mode_flags |= MIPI_DSI_MODE_LPM;

	mipi_dsi_dcs_exit_sleep_mode_multi(&ctx);
	mipi_dsi_msleep(&ctx, 120);

	mipi_dsi_dcs_write_seq_multi(&ctx, 0xd3, 0x4d);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x98, 0x00);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x60, 0x20);	/* 120 Hz */
	mipi_dsi_msleep(&ctx, 50);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0x08, 0x78);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x78, 0x30);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0x39, 0x78);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x78, 0x3c);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0x3e, 0x78);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x78, 0x3c);

	mipi_dsi_compression_mode_multi(&ctx, true);

	drm_dsc_pps_payload_pack(&pps, &priv->dsc);
	mipi_dsi_picture_parameter_set_multi(&ctx, &pps);

	mipi_dsi_dcs_write_seq_multi(&ctx, 0x9a, 0x00);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x79, 0x02);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x86, 0x0a, 0x6b);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0x08, 0x5d);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x5d, 0x00);

	/* TE on, dimming control (stock gamma_mode2 companion write) */
	mipi_dsi_dcs_set_tear_on_multi(&ctx, MIPI_DSI_DCS_TEAR_MODE_VBLANK);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x53, 0x20);

	return ctx.accum_err;
}

static int s6tuum1_prepare(struct drm_panel *panel)
{
	struct s6tuum1 *priv = to_s6tuum1(panel);
	int ret;

	ret = regulator_enable(priv->vdd);
	if (ret < 0)
		return ret;

	/* stock supply entry: 11 ms post-on */
	usleep_range(11000, 12000);
	s6tuum1_reset(priv);

	ret = s6tuum1_on(priv);
	if (ret < 0) {
		gpiod_set_value_cansleep(priv->reset_gpio, 0);
		regulator_disable(priv->vdd);
		return ret;
	}

	return 0;
}

static int s6tuum1_enable(struct drm_panel *panel)
{
	struct s6tuum1 *priv = to_s6tuum1(panel);
	struct mipi_dsi_multi_context ctx = { .dsi = priv->dsi };

	mipi_dsi_dcs_set_display_on_multi(&ctx);
	mipi_dsi_msleep(&ctx, 17);	/* stock display_on wait */

	return ctx.accum_err;
}

static int s6tuum1_disable(struct drm_panel *panel)
{
	struct s6tuum1 *priv = to_s6tuum1(panel);
	struct mipi_dsi_multi_context ctx = { .dsi = priv->dsi };

	mipi_dsi_dcs_set_display_off_multi(&ctx);
	mipi_dsi_dcs_enter_sleep_mode_multi(&ctx);
	mipi_dsi_msleep(&ctx, 100);	/* stock display_off wait */

	return ctx.accum_err;
}

static int s6tuum1_unprepare(struct drm_panel *panel)
{
	struct s6tuum1 *priv = to_s6tuum1(panel);

	gpiod_set_value_cansleep(priv->reset_gpio, 0);
	/* stock supply entry: 15 ms pre-off */
	usleep_range(15000, 16000);
	return regulator_disable(priv->vdd);
}

/* Stock 120 Hz timing: porches h 64/48/64 (fp/bp/pw), v 48/48/64 */
static const struct drm_display_mode s6tuum1_mode = {
	.clock = (2800 + 64 + 64 + 48) * (1752 + 48 + 64 + 48) * 120 / 1000,
	.hdisplay = 2800,
	.hsync_start = 2800 + 64,
	.hsync_end = 2800 + 64 + 64,
	.htotal = 2800 + 64 + 64 + 48,
	.vdisplay = 1752,
	.vsync_start = 1752 + 48,
	.vsync_end = 1752 + 48 + 64,
	.vtotal = 1752 + 48 + 64 + 48,
	.width_mm = 267,
	.height_mm = 167,
	.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
};

static int s6tuum1_get_modes(struct drm_panel *panel,
			     struct drm_connector *connector)
{
	return drm_connector_helper_get_modes_fixed(connector, &s6tuum1_mode);
}

static const struct drm_panel_funcs s6tuum1_panel_funcs = {
	.prepare = s6tuum1_prepare,
	.enable = s6tuum1_enable,
	.disable = s6tuum1_disable,
	.unprepare = s6tuum1_unprepare,
	.get_modes = s6tuum1_get_modes,
};

static int s6tuum1_bl_update_status(struct backlight_device *bl)
{
	struct mipi_dsi_device *dsi = bl_get_data(bl);
	int ret;

	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;
	ret = mipi_dsi_dcs_set_display_brightness_large(dsi,
					backlight_get_brightness(bl));
	dsi->mode_flags |= MIPI_DSI_MODE_LPM;

	return ret;
}

static const struct backlight_ops s6tuum1_bl_ops = {
	.update_status = s6tuum1_bl_update_status,
};

static struct backlight_device *
s6tuum1_create_backlight(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	const struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		/* stock gamma_mode2 normal brightness cmd: 0x51 0x0dd8 */
		.brightness = 0x0dd8,
		.max_brightness = 0x0fff,
	};

	return devm_backlight_device_register(dev, dev_name(dev), dev, dsi,
					      &s6tuum1_bl_ops, &props);
}

static int s6tuum1_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct s6tuum1 *priv;
	int ret;

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->vdd = devm_regulator_get(dev, "vdd");
	if (IS_ERR(priv->vdd))
		return dev_err_probe(dev, PTR_ERR(priv->vdd),
				     "failed to get vdd\n");

	priv->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(priv->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(priv->reset_gpio),
				     "failed to get reset gpio\n");

	priv->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, priv);

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_CLOCK_NON_CONTINUOUS;

	drm_panel_init(&priv->panel, dev, &s6tuum1_panel_funcs,
		       DRM_MODE_CONNECTOR_DSI);
	priv->panel.prepare_prev_first = true;

	priv->panel.backlight = s6tuum1_create_backlight(dsi);
	if (IS_ERR(priv->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(priv->panel.backlight),
				     "failed to create backlight\n");

	drm_panel_add(&priv->panel);

	/* DSC 1.1, decoded from the stock PPS (see device-facts) */
	dsi->dsc = &priv->dsc;
	priv->dsc.dsc_version_major = 1;
	priv->dsc.dsc_version_minor = 1;
	priv->dsc.slice_height = 12;
	priv->dsc.slice_width = 1400;
	priv->dsc.slice_count = 2800 / priv->dsc.slice_width;
	priv->dsc.bits_per_component = 8;
	priv->dsc.bits_per_pixel = 8 << 4;	/* 4 fractional bits */
	priv->dsc.block_pred_enable = true;

	ret = mipi_dsi_attach(dsi);
	if (ret < 0) {
		drm_panel_remove(&priv->panel);
		return dev_err_probe(dev, ret, "failed to attach to DSI host\n");
	}

	return 0;
}

static void s6tuum1_remove(struct mipi_dsi_device *dsi)
{
	struct s6tuum1 *priv = mipi_dsi_get_drvdata(dsi);

	mipi_dsi_detach(dsi);
	drm_panel_remove(&priv->panel);
}

static const struct of_device_id s6tuum1_of_match[] = {
	{ .compatible = "samsung,s6tuum1-amsa24vu01" },
	{ }
};
MODULE_DEVICE_TABLE(of, s6tuum1_of_match);

static struct mipi_dsi_driver s6tuum1_driver = {
	.probe = s6tuum1_probe,
	.remove = s6tuum1_remove,
	.driver = {
		.name = "panel-samsung-s6tuum1",
		.of_match_table = s6tuum1_of_match,
	},
};
module_mipi_dsi_driver(s6tuum1_driver);

MODULE_DESCRIPTION("Samsung S6TUUM1 AMSA24VU01 WQXGA AMOLED panel driver");
MODULE_LICENSE("GPL");
