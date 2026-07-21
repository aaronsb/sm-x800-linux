// SPDX-License-Identifier: GPL-2.0
/*
 * Wacom WEZ01 EMR digitizer (S Pen) — Samsung Galaxy Tab S8+ (gts8pwifi)
 *
 * A mainline-native first cut distilled from Samsung's downstream sec_input
 * wacom driver (kernel-src/drivers/input/wacom/, ~10k lines). It keeps only the
 * path that makes the pen draw: power on, query the chip, register an input
 * device, and translate the 16-byte coordinate packet into pen events. Dropped
 * for now — firmware flash (wez01_flash.c), BLE pen charging, AOP/screen-off
 * gestures, the garage/dock notifier, and the factory sysfs.
 *
 * Chip: i2c 0x56 on &i2c14 (QUP SE14). Protocol + wiring are documented in
 * device-facts/wacom-wez01.md. The chip already runs its app firmware (it ACKs
 * cold), so no firmware load is needed to read it.
 *
 * Coordinate packet (COM_COORD_NUM = 16 bytes, read 17):
 *   data[0]  header: rdy 0x80 (in range), tip 0x10, side-btn 0x20, eraser 0x40
 *   data[1..2]  x   (big-endian)
 *   data[3..4]  y
 *   data[5..6]  pressure  (12-bit: (data[5] & 0x0f) << 8 | data[6])
 *   data[7]     height (hover distance)
 *   data[8]     tilt_x (signed)
 *   data[9]     tilt_y (signed)
 */

#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mod_devicetable.h>
#include <linux/regulator/consumer.h>
#include <linux/slab.h>

/* commands (subset of the downstream wacom_reg.h) */
#define COM_QUERY		0x2a
#define COM_SAMPLERATE_STOP	0x30
#define COM_SAMPLERATE_START	0x31
#define COM_SURVEY_EXIT		0x2d

/* packet geometry (wacom_dev.h) */
#define COM_COORD_NUM		16
#define COM_QUERY_BUFFER	32

/* query block offsets (EPEN_REG_*) */
#define QRY_HEADER		0x00	/* == 0x0f when the block is valid */
#define QRY_X1			0x01
#define QRY_X2			0x02
#define QRY_Y1			0x03
#define QRY_Y2			0x04
#define QRY_PRESSURE1		0x05
#define QRY_PRESSURE2		0x06
#define QRY_FWVER1		0x07
#define QRY_FWVER2		0x08
#define QRY_MPUVER		0x09
#define QRY_TILT_X		0x0b
#define QRY_TILT_Y		0x0c
#define QRY_HEIGHT		0x0d

#define MPU_WEZ01		0x46

/* coord header bits */
#define HDR_RDY			0x80
#define HDR_TIP			0x10
#define HDR_SIDE		0x20
#define HDR_ERASER		0x40

/*
 * Axis mapping from the stock DTB's wacom,invert = <0 1 1> — i.e.
 * x_invert = 0, y_invert = 1, xy_switch = 1 — which rotates the digitizer's
 * portrait frame into the panel's landscape frame. These are the values to
 * revisit first if the pen draws mirrored or rotated (watch the raw packet
 * log, enabled via the module's dyndbg, while moving the pen).
 */
#define WACOM_X_INVERT		0
#define WACOM_Y_INVERT		1
#define WACOM_XY_SWITCH		1

struct wacom_wez01 {
	struct i2c_client *client;
	struct input_dev *input;
	struct regulator *avdd;

	u16 max_x;
	u16 max_y;
	u16 max_pressure;
	u8 max_height;
	s8 max_tilt;

	bool prox;	/* pen currently in range (tool reported down) */
};

static int wacom_send(struct wacom_wez01 *w, u8 cmd)
{
	int ret = i2c_master_send(w->client, &cmd, 1);

	return ret < 0 ? ret : 0;
}

/*
 * Query the chip with a single combined transfer: write COM_QUERY then read the
 * buffer under a repeated start (no STOP between the two messages). The query
 * block lands at the start of the read, tagged by header 0x0f. Fills the
 * geometry fields; returns -EIO if the block never validates.
 *
 * A repeated start is load-bearing on the bit-bang i2c-gpio bus: the separate
 * send + recv path issues a STOP and re-addresses the chip between the command
 * and the read, which dropped the WEZ01's command latch — so the read came back
 * as a stale coord frame (block shifted to offset 16, header always 0xff) and
 * never validated. The combined transfer returns the block at offset 0.
 */
static int wacom_query(struct wacom_wez01 *w)
{
	struct device *dev = &w->client->dev;
	u8 cmd = COM_QUERY;
	u8 buf[COM_QUERY_BUFFER];
	struct i2c_msg msgs[] = {
		{
			.addr = w->client->addr,
			.flags = 0,
			.len = 1,
			.buf = &cmd,
		},
		{
			.addr = w->client->addr,
			.flags = I2C_M_RD,
			.len = COM_QUERY_BUFFER,
			.buf = buf,
		},
	};
	u8 *q;
	int ret, retry;

	for (retry = 0; retry < 5; retry++) {
		ret = i2c_transfer(w->client->adapter, msgs, ARRAY_SIZE(msgs));
		if (ret != ARRAY_SIZE(msgs)) {
			dev_dbg(dev, "query transfer failed: %d\n", ret);
			msleep(20);
			continue;
		}

		q = buf;
		if (q[QRY_HEADER] != 0x0f) {
			dev_dbg(dev, "query header %02x != 0x0f\n", q[QRY_HEADER]);
			msleep(20);
			continue;
		}

		w->max_x = ((u16)q[QRY_X1] << 8) | q[QRY_X2];
		w->max_y = ((u16)q[QRY_Y1] << 8) | q[QRY_Y2];
		w->max_pressure = ((u16)q[QRY_PRESSURE1] << 8) | q[QRY_PRESSURE2];
		w->max_height = q[QRY_HEIGHT];
		w->max_tilt = q[QRY_TILT_X];

		dev_info(dev,
			 "WEZ01 mpu=%02x fw=%02x%02x max_x=%u max_y=%u max_p=%u tilt=%d height=%u\n",
			 q[QRY_MPUVER], q[QRY_FWVER1], q[QRY_FWVER2],
			 w->max_x, w->max_y, w->max_pressure,
			 w->max_tilt, w->max_height);

		if (q[QRY_MPUVER] != MPU_WEZ01)
			dev_warn(dev, "unexpected MPU id %02x (want %02x)\n",
				 q[QRY_MPUVER], MPU_WEZ01);
		return 0;
	}

	return -EIO;
}

/* Apply origin/invert/swap so events land in the panel's landscape frame. */
static void wacom_map_axes(struct wacom_wez01 *w, u16 *x, u16 *y,
			   s8 *tx, s8 *ty)
{
	if (WACOM_X_INVERT) {
		*x = w->max_x - *x;
		*tx = -*tx;
	}
	if (WACOM_Y_INVERT) {
		*y = w->max_y - *y;
		*ty = -*ty;
	}
	if (WACOM_XY_SWITCH) {
		swap(*x, *y);
		swap(*tx, *ty);
	}
}

static irqreturn_t wacom_irq(int irq, void *dev_id)
{
	struct wacom_wez01 *w = dev_id;
	struct input_dev *input = w->input;
	u8 data[COM_COORD_NUM + 1];
	u16 x, y, pressure;
	s8 tilt_x, tilt_y;
	u8 height;
	int ret;

	ret = i2c_master_recv(w->client, data, sizeof(data));
	if (ret != sizeof(data)) {
		dev_dbg(&w->client->dev, "coord recv failed: %d\n", ret);
		return IRQ_HANDLED;
	}

	print_hex_dump_debug("wez01 pkt: ", DUMP_PREFIX_NONE, 16, 1,
			     data, sizeof(data), false);

	/* pen out of range: release everything once */
	if (!(data[0] & HDR_RDY)) {
		if (w->prox) {
			input_report_abs(input, ABS_PRESSURE, 0);
			input_report_abs(input, ABS_DISTANCE, 0);
			input_report_key(input, BTN_TOUCH, 0);
			input_report_key(input, BTN_STYLUS, 0);
			input_report_key(input, BTN_TOOL_PEN, 0);
			input_report_key(input, BTN_TOOL_RUBBER, 0);
			input_sync(input);
			w->prox = false;
		}
		return IRQ_HANDLED;
	}

	x = ((u16)data[1] << 8) | data[2];
	y = ((u16)data[3] << 8) | data[4];
	pressure = ((u16)(data[5] & 0x0f) << 8) | data[6];
	height = data[7];
	tilt_x = (s8)data[8];
	tilt_y = (s8)data[9];

	wacom_map_axes(w, &x, &y, &tilt_x, &tilt_y);

	input_report_key(input, BTN_TOOL_RUBBER, !!(data[0] & HDR_ERASER));
	input_report_key(input, BTN_TOOL_PEN, !(data[0] & HDR_ERASER));
	input_report_key(input, BTN_TOUCH, !!(data[0] & HDR_TIP));
	input_report_key(input, BTN_STYLUS, !!(data[0] & HDR_SIDE));
	input_report_abs(input, ABS_X, x);
	input_report_abs(input, ABS_Y, y);
	input_report_abs(input, ABS_PRESSURE, pressure);
	input_report_abs(input, ABS_DISTANCE, height);
	input_report_abs(input, ABS_TILT_X, tilt_x);
	input_report_abs(input, ABS_TILT_Y, tilt_y);
	input_sync(input);

	w->prox = true;
	return IRQ_HANDLED;
}

static int wacom_setup_input(struct wacom_wez01 *w)
{
	struct input_dev *input;
	u16 abs_x_max, abs_y_max;

	input = devm_input_allocate_device(&w->client->dev);
	if (!input)
		return -ENOMEM;

	input->name = "Wacom WEZ01 S Pen";
	input->id.bustype = BUS_I2C;
	input->dev.parent = &w->client->dev;

	/* the abs ranges are in the post-swap (panel) frame */
	if (WACOM_XY_SWITCH) {
		abs_x_max = w->max_y;
		abs_y_max = w->max_x;
	} else {
		abs_x_max = w->max_x;
		abs_y_max = w->max_y;
	}

	input_set_capability(input, EV_KEY, BTN_TOUCH);
	input_set_capability(input, EV_KEY, BTN_STYLUS);
	input_set_capability(input, EV_KEY, BTN_TOOL_PEN);
	input_set_capability(input, EV_KEY, BTN_TOOL_RUBBER);

	input_set_abs_params(input, ABS_X, 0, abs_x_max, 4, 0);
	input_set_abs_params(input, ABS_Y, 0, abs_y_max, 4, 0);
	input_set_abs_params(input, ABS_PRESSURE, 0, w->max_pressure, 0, 0);
	input_set_abs_params(input, ABS_DISTANCE, 0, w->max_height, 0, 0);
	input_set_abs_params(input, ABS_TILT_X, -w->max_tilt, w->max_tilt, 0, 0);
	input_set_abs_params(input, ABS_TILT_Y, -w->max_tilt, w->max_tilt, 0, 0);

	__set_bit(INPUT_PROP_DIRECT, input->propbit);
	__set_bit(INPUT_PROP_POINTER, input->propbit);

	w->input = input;
	return input_register_device(input);
}

static int wacom_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct wacom_wez01 *w;
	int ret;

	if (!client->irq)
		return dev_err_probe(dev, -EINVAL, "no IRQ\n");

	w = devm_kzalloc(dev, sizeof(*w), GFP_KERNEL);
	if (!w)
		return -ENOMEM;

	w->client = client;
	i2c_set_clientdata(client, w);

	/* sane fallbacks in case the query is unreadable */
	w->max_x = 21658;
	w->max_y = 13538;
	w->max_pressure = 4095;
	w->max_height = 255;
	w->max_tilt = 63;

	w->avdd = devm_regulator_get(dev, "vdd");
	if (IS_ERR(w->avdd))
		return dev_err_probe(dev, PTR_ERR(w->avdd), "no vdd regulator\n");

	ret = regulator_enable(w->avdd);
	if (ret)
		return dev_err_probe(dev, ret, "cannot enable vdd\n");

	/* let the analog front-end settle before the first transaction */
	msleep(100);

	ret = wacom_query(w);
	if (ret)
		dev_warn(dev, "query failed (%d); using fallback geometry\n", ret);

	ret = wacom_setup_input(w);
	if (ret)
		goto err_disable;

	ret = devm_request_threaded_irq(dev, client->irq, NULL, wacom_irq,
					IRQF_ONESHOT, "wacom-wez01", w);
	if (ret) {
		dev_err(dev, "cannot request irq %d: %d\n", client->irq, ret);
		goto err_disable;
	}

	/* start continuous sampling */
	ret = wacom_send(w, COM_SAMPLERATE_START);
	if (ret)
		dev_warn(dev, "samplerate-start failed: %d\n", ret);

	dev_info(dev, "Wacom WEZ01 S Pen ready on irq %d\n", client->irq);
	return 0;

err_disable:
	regulator_disable(w->avdd);
	return ret;
}

static void wacom_remove(struct i2c_client *client)
{
	struct wacom_wez01 *w = i2c_get_clientdata(client);

	wacom_send(w, COM_SAMPLERATE_STOP);
	regulator_disable(w->avdd);
}

static const struct of_device_id wacom_of_match[] = {
	{ .compatible = "wacom,w90xx" },
	{ }
};
MODULE_DEVICE_TABLE(of, wacom_of_match);

static struct i2c_driver wacom_driver = {
	.driver = {
		.name = "wacom-wez01",
		.of_match_table = wacom_of_match,
	},
	.probe = wacom_probe,
	.remove = wacom_remove,
};
module_i2c_driver(wacom_driver);

MODULE_DESCRIPTION("Wacom WEZ01 EMR digitizer (Samsung S Pen, gts8pwifi)");
MODULE_LICENSE("GPL");
