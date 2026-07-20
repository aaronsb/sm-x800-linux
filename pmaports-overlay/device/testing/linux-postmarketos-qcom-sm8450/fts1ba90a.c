// SPDX-License-Identifier: GPL-2.0-only
/*
 * STMicroelectronics FTS1BA90A touchscreen driver (Samsung "FingerTip S").
 *
 * Minimal mainline-style port of Samsung's downstream fts_ts driver
 * (Samsung_Kernel_sm8450_common_gts8x, drivers/input/touchscreen/stm/
 * fts1ba90a/, GPL-2.0), with the sec_input factory/command layer removed.
 *
 * This part is NOT compatible with mainline stmfts.c: it uses 16-byte
 * events read with opcodes 0x60 (one) / 0x61 (all remaining), and scan
 * control via 0xA0, where stmfts speaks an 8-byte-event protocol with a
 * different opcode map. Binding stmfts to it probes -ETIMEDOUT.
 *
 * Only firmware already resident in the IC is used; there is no firmware
 * download path here. The Samsung bootloader chain leaves the IC flashed
 * and this driver only resets and configures it.
 */

#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/input/touchscreen.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>

#define FTS_EVENT_SIZE			16
#define FTS_FIFO_MAX			32
#define FTS_FINGER_MAX			10
#define FTS_I2C_RETRY_CNT		3
#define FTS_RETRY_COUNT			10

/* command opcodes (downstream fts_ts.h) */
#define FTS_CMD_SENSE_OFF		0x11
#define FTS_CMD_FORCE_CALIBRATION	0x13
#define FTS_READ_DEVICE_ID		0x22
#define FTS_READ_PANEL_INFO		0x23
#define FTS_READ_FW_VERSION		0x24
#define FTS_CMD_SET_TOUCH_FUNCTION	0x30
#define FTS_READ_ONE_EVENT		0x60
#define FTS_READ_ALL_EVENT		0x61
#define FTS_CMD_CLEAR_ALL_EVENT		0x62

/* chip id bytes returned by FTS_READ_DEVICE_ID */
#define FTS_ID0				0x39
#define FTS_ID1				0x36

/* 0x30 touch-function bits: touch | palm | wet */
#define FTS_TOUCHTYPE_DEFAULT_ENABLE	0x61

/* event id, low 2 bits of byte 0 */
#define FTS_COORDINATE_EVENT		0
#define FTS_STATUS_EVENT		1
#define FTS_GESTURE_EVENT		2
#define FTS_VENDOR_EVENT		3

/* status events (eid == FTS_STATUS_EVENT), stype in byte0 bits 2-5 */
#define FTS_EVENT_STATUSTYPE_ERROR	1
#define FTS_EVENT_STATUSTYPE_INFO	2
#define FTS_ERR_EVENT_QUEUE_FULL	0x01
#define FTS_ERR_EVENT_ESD		0x02
#define FTS_INFO_READY_STATUS		0x00

/* full byte-0 values */
#define FTS_EVENT_STATUS_REPORT		0x43	/* echo carrier */
#define FTS_EVENT_ERROR_REPORT		0xF3

/* coordinate actions, byte0 bits 6-7 */
#define FTS_ACTION_PRESS		1
#define FTS_ACTION_MOVE			2
#define FTS_ACTION_RELEASE		3

/* touch types accepted as finger contacts */
#define FTS_TTYPE_NORMAL		0
#define FTS_TTYPE_GLOVE			3
#define FTS_TTYPE_PALM			5
#define FTS_TTYPE_WET			6

struct fts1ba90a {
	struct i2c_client *client;
	struct input_dev *input;
	struct touchscreen_properties prop;
	struct regulator *vdd;		/* IO rail, stock tsp_io_ldo (1.848 V) */
	struct regulator *avdd;		/* analog rail, stock tsp_avdd_ldo (3.3 V) */
	struct mutex io_lock;		/* serialises i2c transactions */
	u16 max_x;
	u16 max_y;
};

static int fts1ba90a_write(struct fts1ba90a *ts, const u8 *buf, int len)
{
	struct i2c_msg msg = {
		.addr = ts->client->addr,
		.len = len,
		.buf = (u8 *)buf,
	};
	int retry = FTS_I2C_RETRY_CNT;
	int ret;

	mutex_lock(&ts->io_lock);
	do {
		ret = i2c_transfer(ts->client->adapter, &msg, 1);
		if (ret == 1)
			break;
		usleep_range(10000, 11000);
	} while (--retry > 0);
	mutex_unlock(&ts->io_lock);

	if (ret != 1) {
		dev_err(&ts->client->dev, "write [%02x..] failed: %d\n",
			buf[0], ret);
		return ret < 0 ? ret : -EIO;
	}
	return 0;
}

static int fts1ba90a_read(struct fts1ba90a *ts, const u8 *cmd, int cmd_len,
			  u8 *buf, int len)
{
	struct i2c_msg msgs[2] = {
		{
			.addr = ts->client->addr,
			.len = cmd_len,
			.buf = (u8 *)cmd,
		}, {
			.addr = ts->client->addr,
			.flags = I2C_M_RD,
			.len = len,
			.buf = buf,
		},
	};
	int retry = FTS_I2C_RETRY_CNT;
	int ret;

	mutex_lock(&ts->io_lock);
	do {
		ret = i2c_transfer(ts->client->adapter, msgs, 2);
		if (ret == 2)
			break;
		usleep_range(10000, 11000);
	} while (--retry > 0);
	mutex_unlock(&ts->io_lock);

	if (ret != 2) {
		dev_err(&ts->client->dev, "read [%02x..] failed: %d\n",
			cmd[0], ret);
		return ret < 0 ? ret : -EIO;
	}
	return 0;
}

/*
 * Poll the one-event FIFO until the firmware posts its "ready" status
 * event (stype INFO, id READY). The downstream driver allows 150 poll
 * iterations at 20 ms; keep the same 3 s ceiling.
 */
static int fts1ba90a_wait_for_ready(struct fts1ba90a *ts)
{
	u8 cmd = FTS_READ_ONE_EVENT;
	u8 data[FTS_EVENT_SIZE];
	int err_cnt = 0;
	int retry = 0;
	int ret;

	for (;;) {
		ret = fts1ba90a_read(ts, &cmd, 1, data, FTS_EVENT_SIZE);
		if (ret < 0)
			return ret;

		if (((data[0] >> 2) & 0xf) == FTS_EVENT_STATUSTYPE_INFO &&
		    data[1] == FTS_INFO_READY_STATUS)
			return 0;

		if (data[0] == FTS_EVENT_ERROR_REPORT) {
			/*
			 * 0x20-0x21 / 0xA0-0xA8 flag config/cx corruption,
			 * 0x24 etc. broken OSC trim. Without the factory
			 * tooling there is no recovery path here, so just
			 * name the failure.
			 */
			dev_err(&ts->client->dev,
				"boot error event: %*ph\n", 8, data);
			if (err_cnt++ > 32)
				return -EIO;
			continue;
		}

		if (retry++ > FTS_RETRY_COUNT * 15) {
			dev_err(&ts->client->dev,
				"timed out waiting for ready: %*ph\n", 8, data);
			return -ETIMEDOUT;
		}
		msleep(20);
	}
}

/*
 * Write a command and wait for the firmware to echo it back as a vendor
 * event (0x43 0x01 <cmd bytes>). Commands with side effects (calibration,
 * scan-mode change) complete asynchronously and signal via this echo.
 */
static int fts1ba90a_write_wait_echo(struct fts1ba90a *ts, const u8 *cmd,
				     int cmd_len, int delay_ms)
{
	u8 read_cmd = FTS_READ_ONE_EVENT;
	u8 data[FTS_EVENT_SIZE];
	int cmp = min(cmd_len, 4);
	int retry = 0;
	int ret;

	ret = fts1ba90a_write(ts, cmd, cmd_len);
	if (ret < 0)
		return ret;

	if (delay_ms)
		msleep(delay_ms);

	for (;;) {
		ret = fts1ba90a_read(ts, &read_cmd, 1, data, FTS_EVENT_SIZE);
		if (ret < 0)
			return ret;

		if (data[0] == FTS_EVENT_STATUS_REPORT && data[1] == 0x01 &&
		    !memcmp(&data[2], cmd, cmp))
			return 0;

		if (retry++ > FTS_RETRY_COUNT * 25) {
			dev_err(&ts->client->dev,
				"no echo for cmd %02x: %*ph\n", cmd[0], 8, data);
			return -ETIMEDOUT;
		}
		msleep(20);
	}
}

static int fts1ba90a_system_reset(struct fts1ba90a *ts)
{
	static const u8 reset_cmd[6] = { 0xFA, 0x20, 0x00, 0x00, 0x24, 0x81 };
	static const u8 crc_cmd[5] = { 0xFA, 0x20, 0x00, 0x00, 0x78 };
	u8 crc = 0;
	int ret;

	ret = fts1ba90a_write(ts, reset_cmd, sizeof(reset_cmd));
	if (ret < 0)
		return ret;

	msleep(10);

	/* firmware CRC status; non-fatal, but worth a line if it is bad */
	ret = fts1ba90a_read(ts, crc_cmd, sizeof(crc_cmd), &crc, 1);
	if (ret == 0 && (crc & 0x03))
		dev_warn(&ts->client->dev,
			 "firmware CRC error reported: %02x\n", crc);

	return fts1ba90a_wait_for_ready(ts);
}

static int fts1ba90a_read_ids(struct fts1ba90a *ts)
{
	u8 cmd = FTS_READ_DEVICE_ID;
	u8 id[5] = { 0 };
	u8 ver[9] = { 0 };
	u8 panel[11] = { 0 };
	int ret;

	ret = fts1ba90a_read(ts, &cmd, 1, id, sizeof(id));
	if (ret < 0)
		return ret;

	if (id[2] != FTS_ID0 && id[3] != FTS_ID1) {
		dev_err(&ts->client->dev, "unexpected chip id: %*ph\n", 5, id);
		return -ENODEV;
	}

	cmd = FTS_READ_FW_VERSION;
	ret = fts1ba90a_read(ts, &cmd, 1, ver, sizeof(ver));
	if (ret < 0)
		return ret;

	cmd = FTS_READ_PANEL_INFO;
	ret = fts1ba90a_read(ts, &cmd, 1, panel, sizeof(panel));
	if (ret < 0)
		return ret;

	ts->max_x = (panel[0] << 8) | panel[1];
	ts->max_y = (panel[2] << 8) | panel[3];

	dev_info(&ts->client->dev,
		 "%c%c id %02x%02x fw 0x%04x cfg 0x%04x main 0x%04x, %ux%u, tx/rx %u/%u\n",
		 id[0], id[1], id[2], id[3],
		 (ver[0] << 8) | ver[1], (ver[2] << 8) | ver[3],
		 ver[4] | (ver[5] << 8),
		 ts->max_x + 1, ts->max_y + 1, panel[8], panel[9]);

	return 0;
}

/*
 * Post-reset configuration: enable the default touch types, clear the
 * event FIFO and start mutual/self scanning (0xA0). Calibration (0x13)
 * is only run on probe, mirroring downstream fts_init vs fts_reinit.
 */
static int fts1ba90a_configure(struct fts1ba90a *ts, bool calibrate)
{
	static const u8 touch_fn[3] = { FTS_CMD_SET_TOUCH_FUNCTION,
					FTS_TOUCHTYPE_DEFAULT_ENABLE, 0x00 };
	static const u8 cal_cmd[1] = { FTS_CMD_FORCE_CALIBRATION };
	static const u8 clear_cmd[1] = { FTS_CMD_CLEAR_ALL_EVENT };
	static const u8 scan_cmd[3] = { 0xA0, 0x00, 0x01 }; /* MS/SS scan */
	int ret;

	ret = fts1ba90a_write(ts, touch_fn, sizeof(touch_fn));
	if (ret < 0)
		return ret;

	msleep(10);

	if (calibrate) {
		ret = fts1ba90a_write_wait_echo(ts, cal_cmd, sizeof(cal_cmd), 0);
		if (ret < 0)
			dev_warn(&ts->client->dev, "calibration not confirmed\n");
	}

	ret = fts1ba90a_write_wait_echo(ts, clear_cmd, sizeof(clear_cmd), 0);
	if (ret < 0)
		return ret;

	return fts1ba90a_write_wait_echo(ts, scan_cmd, sizeof(scan_cmd), 0);
}

static int fts1ba90a_power_on(struct fts1ba90a *ts)
{
	int ret;

	ret = regulator_enable(ts->vdd);
	if (ret)
		return ret;
	usleep_range(1000, 1500);
	ret = regulator_enable(ts->avdd);
	if (ret) {
		regulator_disable(ts->vdd);
		return ret;
	}
	msleep(10);
	return 0;
}

static void fts1ba90a_power_off(struct fts1ba90a *ts)
{
	regulator_disable(ts->avdd);
	usleep_range(4000, 5000);
	regulator_disable(ts->vdd);
}

static void fts1ba90a_release_all(struct fts1ba90a *ts)
{
	int i;

	for (i = 0; i < FTS_FINGER_MAX; i++) {
		input_mt_slot(ts->input, i);
		input_mt_report_slot_inactive(ts->input);
	}
	input_mt_sync_frame(ts->input);
	input_sync(ts->input);
}

static void fts1ba90a_handle_coordinate(struct fts1ba90a *ts, const u8 *ev)
{
	u8 tid = (ev[0] >> 2) & 0xf;
	u8 action = ev[0] >> 6;
	u8 ttype = ((ev[6] >> 6) << 2) | (ev[7] >> 6);
	u16 x = (ev[1] << 4) | (ev[3] >> 4);
	u16 y = (ev[2] << 4) | (ev[3] & 0xf);

	if (tid >= FTS_FINGER_MAX)
		return;

	/* hover/proximity/stylus and friends are not reported */
	if (ttype != FTS_TTYPE_NORMAL && ttype != FTS_TTYPE_PALM &&
	    ttype != FTS_TTYPE_WET && ttype != FTS_TTYPE_GLOVE)
		return;

	input_mt_slot(ts->input, tid);

	switch (action) {
	case FTS_ACTION_PRESS:
	case FTS_ACTION_MOVE:
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, true);
		touchscreen_report_pos(ts->input, &ts->prop, x, y, true);
		input_report_abs(ts->input, ABS_MT_TOUCH_MAJOR, ev[4]);
		input_report_abs(ts->input, ABS_MT_TOUCH_MINOR, ev[5]);
		break;
	case FTS_ACTION_RELEASE:
		input_mt_report_slot_inactive(ts->input);
		break;
	}
}

static void fts1ba90a_handle_status(struct fts1ba90a *ts, const u8 *ev)
{
	u8 stype = (ev[0] >> 2) & 0xf;

	if (stype != FTS_EVENT_STATUSTYPE_ERROR)
		return;

	if (ev[1] == FTS_ERR_EVENT_QUEUE_FULL) {
		dev_err(&ts->client->dev, "event queue full, releasing\n");
		fts1ba90a_release_all(ts);
	} else if (ev[1] == FTS_ERR_EVENT_ESD) {
		/*
		 * Downstream schedules a full reset here. Log it first; if
		 * it ever fires in practice, wire up a reset worker.
		 */
		dev_err(&ts->client->dev, "ESD error reported\n");
	}
}

static irqreturn_t fts1ba90a_irq_handler(int irq, void *dev_id)
{
	struct fts1ba90a *ts = dev_id;
	u8 data[FTS_FIFO_MAX * FTS_EVENT_SIZE];
	u8 cmd = FTS_READ_ONE_EVENT;
	int left, i;

	if (fts1ba90a_read(ts, &cmd, 1, data, FTS_EVENT_SIZE) < 0)
		return IRQ_HANDLED;

	left = data[7] & 0x3f;
	if (left >= FTS_FIFO_MAX)
		left = FTS_FIFO_MAX - 1;

	if (left > 0) {
		cmd = FTS_READ_ALL_EVENT;
		if (fts1ba90a_read(ts, &cmd, 1, &data[FTS_EVENT_SIZE],
				   left * FTS_EVENT_SIZE) < 0)
			left = 0;
	}

	for (i = 0; i <= left; i++) {
		const u8 *ev = &data[i * FTS_EVENT_SIZE];

		switch (ev[0] & 0x3) {
		case FTS_COORDINATE_EVENT:
			fts1ba90a_handle_coordinate(ts, ev);
			break;
		case FTS_STATUS_EVENT:
			fts1ba90a_handle_status(ts, ev);
			break;
		default:
			dev_dbg(&ts->client->dev, "event: %*ph\n", 8, ev);
			break;
		}
	}

	input_mt_sync_frame(ts->input);
	input_sync(ts->input);

	return IRQ_HANDLED;
}

static int fts1ba90a_probe(struct i2c_client *client)
{
	struct fts1ba90a *ts;
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
		return -ENXIO;

	ts = devm_kzalloc(&client->dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;

	ts->client = client;
	mutex_init(&ts->io_lock);
	i2c_set_clientdata(client, ts);

	ts->vdd = devm_regulator_get(&client->dev, "vdd");
	if (IS_ERR(ts->vdd))
		return dev_err_probe(&client->dev, PTR_ERR(ts->vdd),
				     "failed to get vdd\n");

	ts->avdd = devm_regulator_get(&client->dev, "avdd");
	if (IS_ERR(ts->avdd))
		return dev_err_probe(&client->dev, PTR_ERR(ts->avdd),
				     "failed to get avdd\n");

	ret = fts1ba90a_power_on(ts);
	if (ret)
		return dev_err_probe(&client->dev, ret, "failed to power on\n");

	ret = fts1ba90a_system_reset(ts);
	if (ret < 0)
		goto err_power_off;

	ret = fts1ba90a_read_ids(ts);
	if (ret < 0)
		goto err_power_off;

	ret = fts1ba90a_configure(ts, true);
	if (ret < 0)
		goto err_power_off;

	ts->input = devm_input_allocate_device(&client->dev);
	if (!ts->input) {
		ret = -ENOMEM;
		goto err_power_off;
	}

	ts->input->name = "STMicroelectronics FTS1BA90A";
	ts->input->phys = "input/ts";
	ts->input->id.bustype = BUS_I2C;

	input_set_abs_params(ts->input, ABS_MT_POSITION_X, 0, ts->max_x, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_POSITION_Y, 0, ts->max_y, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_TOUCH_MAJOR, 0, 255, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_TOUCH_MINOR, 0, 255, 0, 0);
	touchscreen_parse_properties(ts->input, true, &ts->prop);

	ret = input_mt_init_slots(ts->input, FTS_FINGER_MAX, INPUT_MT_DIRECT);
	if (ret)
		goto err_power_off;

	ret = input_register_device(ts->input);
	if (ret)
		goto err_power_off;

	ret = devm_request_threaded_irq(&client->dev, client->irq, NULL,
					fts1ba90a_irq_handler, IRQF_ONESHOT,
					"fts1ba90a", ts);
	if (ret) {
		dev_err_probe(&client->dev, ret, "failed to request irq %d\n",
			      client->irq);
		goto err_power_off;
	}

	return 0;

err_power_off:
	fts1ba90a_power_off(ts);
	return ret;
}

static void fts1ba90a_remove(struct i2c_client *client)
{
	struct fts1ba90a *ts = i2c_get_clientdata(client);

	disable_irq(client->irq);
	fts1ba90a_power_off(ts);
}

static int fts1ba90a_suspend(struct device *dev)
{
	struct fts1ba90a *ts = dev_get_drvdata(dev);
	static const u8 sense_off[1] = { FTS_CMD_SENSE_OFF };

	disable_irq(ts->client->irq);
	fts1ba90a_write(ts, sense_off, sizeof(sense_off));
	fts1ba90a_release_all(ts);
	fts1ba90a_power_off(ts);

	return 0;
}

static int fts1ba90a_resume(struct device *dev)
{
	struct fts1ba90a *ts = dev_get_drvdata(dev);
	int ret;

	ret = fts1ba90a_power_on(ts);
	if (ret)
		return ret;

	ret = fts1ba90a_wait_for_ready(ts);
	if (ret < 0)
		dev_err(dev, "resume: ready wait failed: %d\n", ret);

	ret = fts1ba90a_system_reset(ts);
	if (ret == 0)
		ret = fts1ba90a_configure(ts, false);
	if (ret < 0)
		dev_err(dev, "resume: reconfigure failed: %d\n", ret);

	enable_irq(ts->client->irq);

	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(fts1ba90a_pm_ops,
				fts1ba90a_suspend, fts1ba90a_resume);

static const struct of_device_id fts1ba90a_of_match[] = {
	{ .compatible = "st,fts1ba90a" },
	{ }
};
MODULE_DEVICE_TABLE(of, fts1ba90a_of_match);

static const struct i2c_device_id fts1ba90a_id[] = {
	{ "fts1ba90a" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, fts1ba90a_id);

static struct i2c_driver fts1ba90a_driver = {
	.driver = {
		.name = "fts1ba90a",
		.of_match_table = fts1ba90a_of_match,
		.pm = pm_sleep_ptr(&fts1ba90a_pm_ops),
		.probe_type = PROBE_PREFER_ASYNCHRONOUS,
	},
	.probe = fts1ba90a_probe,
	.remove = fts1ba90a_remove,
	.id_table = fts1ba90a_id,
};
module_i2c_driver(fts1ba90a_driver);

MODULE_DESCRIPTION("STMicroelectronics FTS1BA90A touchscreen driver");
MODULE_LICENSE("GPL");
