// SPDX-License-Identifier: GPL-2.0-only
/*
 * Samsung pogo-pin Book Cover Keyboard driver (STM32G0 MCU).
 *
 * Minimal mainline-style port of Samsung's downstream stm32_pogo driver
 * stack (Samsung_Kernel_sm8450_common_gts8x, drivers/input/sec_input/
 * stm32/, GPL-2.0), collapsed into one file: connection state machine,
 * keyboard matrix and touchpad. Dropped relative to downstream: firmware
 * update (MCU firmware is already correct — flash-dumped and verified
 * byte-identical to stock), sysfs factory interface, notifier chain,
 * interconnect voting, and the in-driver touchpad left/right-zone
 * heuristics (the pad is reported as a standard MT clickpad and
 * userspace/libinput owns that policy).
 *
 * How the link comes up — this is the part 12k userspace probes of 0x2a
 * could never do: the MCU only serves its I2C slave interface as part of
 * an interrupt-driven handshake.
 *   1. conn (tlmm 59, driven by the keyboard) goes high on dock.
 *   2. Host enables the VDDO rail (tlmm 70 gpio regulator), waits 50 ms,
 *      and enables the ATTN irq (tlmm 71, level low, driven by the MCU).
 *   3. The MCU pulls ATTN low. The host answers with a "header write"
 *      { len_lo, len_hi, ep } at 0x2a and reads back a 3-byte header.
 *   4. The first exchange has an empty payload; its ep byte carries the
 *      keyboard model. The host then reads the MCU version and pushes it
 *      into APP mode (GET_MODE / ABORT). From then on ATTN signals real
 *      events: ep 2 = touchpad, 3 = keypad, 4 = hall, 5 = accessory.
 *
 * The ep byte of the host's header write doubles as the caps-lock LED
 * state: 0x01 = LED off, 0x02 = LED on.
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/interrupt.h>
#include <linux/irq.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>
#include <linux/workqueue.h>

#define STM32_MAX_EVENT_SIZE		100
#define STM32_I2C_RETRY_CNT		3

/* endpoint ids (also event ids in the read-back header) */
#define STM32_EP_MCU			1
#define STM32_EP_TOUCHPAD		2
#define STM32_EP_KEYPAD			3
#define STM32_EP_HALL			4
#define STM32_EP_ACCESSORY		5

/* MCU register commands (via header write + reg write on EP_MCU) */
#define STM32_CMD_GET_MODE		0x01
#define STM32_CMD_CHECK_VERSION		0x02
#define STM32_CMD_CHECK_CRC		0x03
#define STM32_CMD_ABORT			0x17	/* leave DFU, run app */
#define STM32_CMD_GET_TC_FW_VERSION	0x18
#define STM32_CMD_GET_TC_RESOLUTION	0x1A

#define STM32_MODE_APP			1
#define STM32_MODE_DFU			2
#define STM32_MODE_EXCEPTION		3

/* keyboard matrix */
#define STM32_KPD_ROWS			8
#define STM32_KPD_COLS			24

/* touchpad packet (zinitix-style) */
#define STM32_TP_FINGERS		3
#define STM32_TP_STATUS_PT_EXIST	BIT(11)
#define STM32_TP_STATUS_ICON_EVENT	BIT(15)
#define STM32_TP_BUTTON_DOWN		BIT(0)
#define STM32_TP_SUB_EXIST		BIT(0)

struct stm32_tp_coord {
	__le16 x;
	__le16 y;
	u8 w;
	u8 sub_status;
} __packed;

struct stm32_tp_packet {
	__le16 status;
	u8 finger_cnt;
	u8 button_info;
	struct stm32_tp_coord coords[STM32_TP_FINGERS];
} __packed;

/*
 * Keymaps lifted from the stock DTB's pogo_kpd node (linux,keymap1/2,
 * 8 rows x 24 columns). keymap2 (Slim Book Cover Keyboard, EF-DT730,
 * model_id 1) differs from keymap1 (Book Cover Keyboard, EF-DT970,
 * model_id 0) only at row 7 cols 17/18, patched at attach time.
 * Codes above KEY_MAX-ish (0x2xx) are Samsung's Android soft keys
 * (SIP, Finder, DeX...); they are reported as-is.
 */
static const u16 stm32_pogo_keymap[STM32_KPD_ROWS][STM32_KPD_COLS] = {
	{ 0x000, 0x000, 0x000, 0x000, 0x02c, 0x056, 0x000, 0x02f, 0x032, 0x06c, 0x000, 0x039, 0x067, 0x000, 0x000, 0x000, 0x001, 0x072, 0x000, 0x000, 0x000, 0x000, 0x2c2, 0x000 },
	{ 0x000, 0x000, 0x1d0, 0x07d, 0x01e, 0x02d, 0x020, 0x030, 0x000, 0x033, 0x034, 0x035, 0x000, 0x000, 0x000, 0x000, 0x2c1, 0x073, 0x000, 0x000, 0x000, 0x000, 0x066, 0x000 },
	{ 0x000, 0x000, 0x07a, 0x000, 0x010, 0x000, 0x02e, 0x021, 0x024, 0x025, 0x026, 0x027, 0x000, 0x01c, 0x000, 0x000, 0x0fe, 0x0a5, 0x000, 0x000, 0x000, 0x000, 0x068, 0x000 },
	{ 0x000, 0x000, 0x038, 0x000, 0x00f, 0x011, 0x012, 0x022, 0x023, 0x017, 0x028, 0x019, 0x000, 0x000, 0x000, 0x000, 0x0ac, 0x0a4, 0x000, 0x000, 0x000, 0x000, 0x06d, 0x000 },
	{ 0x03a, 0x064, 0x000, 0x000, 0x002, 0x003, 0x004, 0x013, 0x016, 0x009, 0x018, 0x00b, 0x000, 0x000, 0x000, 0x02b, 0x0e0, 0x0a3, 0x000, 0x000, 0x000, 0x000, 0x06b, 0x000 },
	{ 0x000, 0x01d, 0x000, 0x06a, 0x029, 0x03e, 0x041, 0x014, 0x015, 0x044, 0x01a, 0x00e, 0x000, 0x00c, 0x000, 0x01b, 0x0e1, 0x2c5, 0x000, 0x000, 0x000, 0x2bd, 0x2cb, 0x000 },
	{ 0x036, 0x069, 0x000, 0x000, 0x03b, 0x03d, 0x040, 0x005, 0x008, 0x043, 0x00a, 0x058, 0x031, 0x000, 0x000, 0x000, 0x07d, 0x06f, 0x000, 0x000, 0x000, 0x000, 0x2ca, 0x000 },
	{ 0x02a, 0x2c6, 0x000, 0x01f, 0x001, 0x03c, 0x03f, 0x006, 0x007, 0x042, 0x00d, 0x057, 0x000, 0x063, 0x06f, 0x000, 0x071, 0x214, 0x213, 0x000, 0x000, 0x000, 0x000, 0x000 },
};

struct stm32_pogo {
	struct i2c_client *client;
	struct input_dev *kbd;		/* live only while docked */
	struct input_dev *tp;		/* live only while docked, if pad present */
	struct regulator *vdd;
	struct gpio_desc *conn_gpio;
	struct gpio_desc *attn_gpio;
	struct gpio_desc *nrst_gpio;
	int conn_irq;
	int attn_irq;
	struct mutex i2c_lock;		/* one header+payload exchange at a time */
	struct mutex dev_lock;		/* connection state machine */
	struct delayed_work conn_work;
	struct delayed_work init_work;	/* handshake watchdog */
	struct delayed_work ic_work;	/* post-handshake chip setup */
	bool started;			/* rail on, attn irq live */
	bool handshaken;		/* first empty exchange seen */
	u8 model_id;
	u8 led_ep;			/* 1 = caps LED off, 2 = on */
	u32 key_state[STM32_KPD_ROWS];
	u16 keymap[STM32_KPD_ROWS][STM32_KPD_COLS];
	u8 prev_sub[STM32_TP_FINGERS];
	u32 tp_size_x;
	u32 tp_size_y;
	bool tp_present;
};

static int stm32_pogo_xfer(struct stm32_pogo *pogo, struct i2c_msg *msgs, int num)
{
	int retry = STM32_I2C_RETRY_CNT;
	int ret;

	do {
		ret = i2c_transfer(pogo->client->adapter, msgs, num);
		if (ret == num)
			return 0;
		usleep_range(1000, 1100);
	} while (--retry > 0);

	dev_err(&pogo->client->dev, "i2c xfer failed: %d (conn:%d attn:%d)\n",
		ret, gpiod_get_value(pogo->conn_gpio),
		gpiod_get_value(pogo->attn_gpio));

	/*
	 * Downstream pulses nRST here to recover a wedged MCU. Keep it: a
	 * failed transfer mid-session otherwise leaves the link dead until
	 * the next dock cycle.
	 */
	if (pogo->started) {
		gpiod_set_value(pogo->nrst_gpio, 0);
		msleep(3);
		gpiod_set_value(pogo->nrst_gpio, 1);
		msleep(10);
	}

	return ret < 0 ? ret : -EIO;
}

static int stm32_pogo_write(struct stm32_pogo *pogo, const u8 *data, int len)
{
	struct i2c_msg msg = {
		.addr = pogo->client->addr,
		.len = len,
		.buf = (u8 *)data,
	};

	return stm32_pogo_xfer(pogo, &msg, 1);
}

static int stm32_pogo_read(struct stm32_pogo *pogo, u8 *data, int len)
{
	struct i2c_msg msg = {
		.addr = pogo->client->addr,
		.flags = I2C_M_RD,
		.len = len,
		.buf = data,
	};

	return stm32_pogo_xfer(pogo, &msg, 1);
}

/* { total_len_lo, total_len_hi, ep } where total_len includes the header */
static int stm32_pogo_header_write(struct stm32_pogo *pogo, u8 ep, u16 payload)
{
	u8 buf[3];

	payload += 3;
	buf[0] = payload & 0xff;
	buf[1] = payload >> 8;
	buf[2] = ep;

	return stm32_pogo_write(pogo, buf, sizeof(buf));
}

static int stm32_pogo_reg_read(struct stm32_pogo *pogo, u8 ep, u8 reg,
			       u8 *val, u16 len)
{
	u8 hdr[3];
	u16 payload;
	int ret;

	mutex_lock(&pogo->i2c_lock);

	ret = stm32_pogo_header_write(pogo, ep, 1);
	if (ret < 0)
		goto out;
	ret = stm32_pogo_write(pogo, &reg, 1);
	if (ret < 0)
		goto out;

	ret = stm32_pogo_read(pogo, hdr, 3);
	if (ret < 0)
		goto out;

	payload = (hdr[1] << 8 | hdr[0]) - 3;
	if (payload == 0 || payload > 0xff || payload > len) {
		dev_err(&pogo->client->dev, "bad payload size %u for reg %02x\n",
			payload, reg);
		ret = -EIO;
		goto out;
	}

	ret = stm32_pogo_read(pogo, val, payload);
out:
	mutex_unlock(&pogo->i2c_lock);
	return ret;
}

static int stm32_pogo_reg_write(struct stm32_pogo *pogo, u8 ep, u8 reg)
{
	int ret;

	mutex_lock(&pogo->i2c_lock);
	ret = stm32_pogo_header_write(pogo, ep, 1);
	if (!ret)
		ret = stm32_pogo_write(pogo, &reg, 1);
	mutex_unlock(&pogo->i2c_lock);
	return ret;
}

/* ---------------------------------------------------------------- input */

static void stm32_pogo_release_keys(struct stm32_pogo *pogo)
{
	int r, c;

	if (!pogo->kbd)
		return;

	for (r = 0; r < STM32_KPD_ROWS; r++) {
		if (!pogo->key_state[r])
			continue;
		for (c = 0; c < STM32_KPD_COLS; c++) {
			if (!(pogo->key_state[r] & BIT(c)))
				continue;
			input_event(pogo->kbd, EV_MSC, MSC_SCAN, (r << 5) | c);
			input_report_key(pogo->kbd, pogo->keymap[r][c], 0);
		}
		pogo->key_state[r] = 0;
	}
	input_sync(pogo->kbd);
}

static void stm32_pogo_release_fingers(struct stm32_pogo *pogo)
{
	int i;

	if (!pogo->tp)
		return;

	for (i = 0; i < STM32_TP_FINGERS; i++) {
		input_mt_slot(pogo->tp, i);
		input_mt_report_slot_inactive(pogo->tp);
		pogo->prev_sub[i] = 0;
	}
	input_report_key(pogo->tp, BTN_LEFT, 0);
	input_mt_sync_frame(pogo->tp);
	input_sync(pogo->tp);
}

static void stm32_pogo_keypad_event(struct stm32_pogo *pogo, const u8 *data,
				    int len)
{
	int i;

	if (!pogo->kbd)
		return;

	/* u16 LE per event: bit0 press, bits1-5 col, bits6-8 row */
	for (i = 0; i + 1 < len; i += 2) {
		u16 ev = data[i] | (data[i + 1] << 8);
		unsigned int press = ev & 1;
		unsigned int col = (ev >> 1) & 0x1f;	/* 5 bits: can exceed 23 */
		unsigned int row = (ev >> 6) & 0x7;
		u16 code;

		if (col >= STM32_KPD_COLS)
			continue;
		code = pogo->keymap[row][col];

		if (press)
			pogo->key_state[row] |= BIT(col);
		else
			pogo->key_state[row] &= ~BIT(col);

		input_event(pogo->kbd, EV_MSC, MSC_SCAN, (row << 5) | col);
		input_report_key(pogo->kbd, code, press);
		input_sync(pogo->kbd);
	}
}

static void stm32_pogo_touchpad_event(struct stm32_pogo *pogo, const u8 *data,
				      int len)
{
	const struct stm32_tp_packet *pkt = (const void *)data;
	u16 status;
	int i;

	if (!pogo->tp || len != sizeof(*pkt))
		return;

	status = le16_to_cpu(pkt->status);

	for (i = 0; i < STM32_TP_FINGERS; i++) {
		u8 sub = pkt->coords[i].sub_status;
		bool exists = (status & STM32_TP_STATUS_PT_EXIST) &&
			      (sub & STM32_TP_SUB_EXIST);

		input_mt_slot(pogo->tp, i);
		if (exists) {
			/*
			 * Stock transform for this pad: invert y, then swap
			 * axes (touchpad,invert = <0 1 1> downstream).
			 */
			int x = le16_to_cpu(pkt->coords[i].x);
			int y = le16_to_cpu(pkt->coords[i].y);
			int w = pkt->coords[i].w ? pkt->coords[i].w : 1;

			if (x >= pogo->tp_size_x || y >= pogo->tp_size_y)
				continue;
			y = pogo->tp_size_y - 1 - y;
			swap(x, y);

			input_mt_report_slot_state(pogo->tp, MT_TOOL_FINGER, true);
			input_report_abs(pogo->tp, ABS_MT_POSITION_X, x);
			input_report_abs(pogo->tp, ABS_MT_POSITION_Y, y);
			input_report_abs(pogo->tp, ABS_MT_TOUCH_MAJOR, w);
		} else if (pogo->prev_sub[i] & STM32_TP_SUB_EXIST) {
			input_mt_report_slot_inactive(pogo->tp);
		}
		pogo->prev_sub[i] = exists ? sub : 0;
	}

	if (status & STM32_TP_STATUS_ICON_EVENT)
		input_report_key(pogo->tp, BTN_LEFT,
				 !!(pkt->button_info & STM32_TP_BUTTON_DOWN));

	input_mt_sync_frame(pogo->tp);
	input_sync(pogo->tp);
}

static int stm32_pogo_kbd_led_event(struct input_dev *dev, unsigned int type,
				    unsigned int code, int value)
{
	struct stm32_pogo *pogo = input_get_drvdata(dev);

	if (type != EV_LED)
		return -1;

	pogo->led_ep = test_bit(LED_CAPSL, dev->led) ? 0x2 : 0x1;
	return 0;
}

static int stm32_pogo_register_kbd(struct stm32_pogo *pogo)
{
	struct input_dev *kbd;
	int r, c, ret;

	kbd = input_allocate_device();
	if (!kbd)
		return -ENOMEM;

	memcpy(pogo->keymap, stm32_pogo_keymap, sizeof(pogo->keymap));
	if (pogo->model_id == 1) {
		/* Slim Book Cover Keyboard (EF-DT730) */
		pogo->keymap[7][17] = 0x2c9;
		pogo->keymap[7][18] = 0;
	}

	kbd->name = pogo->model_id == 1 ?
		"Book Cover Keyboard Slim (EF-DT730)" :
		"Book Cover Keyboard (EF-DT970)";
	kbd->phys = "pogo/input0";
	kbd->id.bustype = BUS_I2C;
	kbd->id.vendor = 0x04e8;
	kbd->id.product = 0xa035;
	kbd->dev.parent = &pogo->client->dev;
	kbd->event = stm32_pogo_kbd_led_event;

	input_set_capability(kbd, EV_MSC, MSC_SCAN);
	input_set_capability(kbd, EV_LED, LED_CAPSL);
	/*
	 * The MCU reports only press/release transitions — no hardware
	 * autorepeat. EV_REP makes the input core software-repeat held keys
	 * (holding an arrow actually scrolls).
	 */
	__set_bit(EV_REP, kbd->evbit);
	for (r = 0; r < STM32_KPD_ROWS; r++)
		for (c = 0; c < STM32_KPD_COLS; c++)
			if (pogo->keymap[r][c])
				input_set_capability(kbd, EV_KEY,
						     pogo->keymap[r][c]);

	input_set_drvdata(kbd, pogo);

	ret = input_register_device(kbd);
	if (ret) {
		input_free_device(kbd);
		return ret;
	}

	memset(pogo->key_state, 0, sizeof(pogo->key_state));
	pogo->kbd = kbd;
	return 0;
}

static int stm32_pogo_register_tp(struct stm32_pogo *pogo)
{
	struct input_dev *tp;
	int ret;

	tp = input_allocate_device();
	if (!tp)
		return -ENOMEM;

	tp->name = "Book Cover Keyboard Touchpad";
	tp->phys = "pogo/input1";
	tp->id.bustype = BUS_I2C;
	tp->id.vendor = 0x04e8;
	tp->id.product = 0xa036;
	tp->dev.parent = &pogo->client->dev;

	/* post-transform ranges: x = inverted raw y, y = raw x */
	input_set_abs_params(tp, ABS_MT_POSITION_X, 0, pogo->tp_size_y - 1, 0, 0);
	input_set_abs_params(tp, ABS_MT_POSITION_Y, 0, pogo->tp_size_x - 1, 0, 0);
	input_set_abs_params(tp, ABS_MT_TOUCH_MAJOR, 0, 255, 0, 0);
	input_set_capability(tp, EV_KEY, BTN_LEFT);
	__set_bit(INPUT_PROP_POINTER, tp->propbit);
	__set_bit(INPUT_PROP_BUTTONPAD, tp->propbit);

	ret = input_mt_init_slots(tp, STM32_TP_FINGERS,
				  INPUT_MT_POINTER | INPUT_MT_DROP_UNUSED);
	if (ret) {
		input_free_device(tp);
		return ret;
	}

	ret = input_register_device(tp);
	if (ret) {
		input_free_device(tp);
		return ret;
	}

	memset(pogo->prev_sub, 0, sizeof(pogo->prev_sub));
	pogo->tp = tp;
	return 0;
}

static void stm32_pogo_unregister_inputs(struct stm32_pogo *pogo)
{
	if (pogo->kbd) {
		stm32_pogo_release_keys(pogo);
		input_unregister_device(pogo->kbd);
		pogo->kbd = NULL;
	}
	if (pogo->tp) {
		stm32_pogo_release_fingers(pogo);
		input_unregister_device(pogo->tp);
		pogo->tp = NULL;
	}
}

/* -------------------------------------------------- connection machine */

static int stm32_pogo_read_version(struct stm32_pogo *pogo)
{
	u8 buf[4] = { 0 };
	int ret;

	ret = stm32_pogo_reg_read(pogo, STM32_EP_MCU, STM32_CMD_CHECK_VERSION,
				  buf, sizeof(buf));
	if (ret < 0)
		return ret;

	pogo->model_id = (buf[1] <= 2) ? buf[1] : 0;
	dev_info(&pogo->client->dev,
		 "keyboard fw v%u.%u, model_id %u, hw rev %u\n",
		 buf[3], buf[2], pogo->model_id, buf[0]);
	return 0;
}

/*
 * Post-handshake chip setup, mirroring downstream check_ic_work: make
 * sure the MCU app is running (not DFU), then probe for the touchpad.
 */
static void stm32_pogo_ic_work(struct work_struct *work)
{
	struct stm32_pogo *pogo = container_of(to_delayed_work(work),
					       struct stm32_pogo, ic_work);
	u8 buf[6] = { 0 };
	u8 mode;
	int ret;

	mutex_lock(&pogo->dev_lock);

	if (!pogo->started || !pogo->handshaken)
		goto out;

	ret = stm32_pogo_reg_read(pogo, STM32_EP_MCU, STM32_CMD_GET_MODE,
				  &mode, 1);
	if (ret < 0)
		goto out;

	if (mode != STM32_MODE_APP && mode != STM32_MODE_EXCEPTION) {
		dev_info(&pogo->client->dev, "mode %u, entering APP\n", mode);
		stm32_pogo_reg_write(pogo, STM32_EP_MCU, STM32_CMD_ABORT);
		msleep(200);
	}

	/*
	 * Touchpad presence, downstream semantics: pad absent iff the u16
	 * TC major version is 0xff AND the u16 minor is 0. The Slim
	 * keyboard (EF-DT730) reports exactly that — and byte-wise
	 * comparison gets it wrong (major 0x00ff is bytes 00 ff).
	 */
	pogo->tp_present = false;
	ret = stm32_pogo_reg_read(pogo, STM32_EP_TOUCHPAD,
				  STM32_CMD_GET_TC_FW_VERSION, buf, sizeof(buf));
	if (ret == 0) {
		u16 tc_major = buf[3] << 8 | buf[2];
		u16 tc_minor = buf[5] << 8 | buf[4];

		pogo->tp_present = !(tc_major == 0xff && tc_minor == 0);
	}
	if (pogo->tp_present) {
		u8 res[4] = { 0 };

		ret = stm32_pogo_reg_read(pogo, STM32_EP_TOUCHPAD,
					  STM32_CMD_GET_TC_RESOLUTION,
					  res, sizeof(res));
		if (ret == 0 && (res[3] << 8 | res[2]) &&
		    (res[1] << 8 | res[0])) {
			pogo->tp_size_x = res[3] << 8 | res[2];
			pogo->tp_size_y = res[1] << 8 | res[0];
		}
		dev_info(&pogo->client->dev, "touchpad %ux%u, TC fw %02x%02x\n",
			 pogo->tp_size_x, pogo->tp_size_y, buf[3], buf[2]);
	}

	if (!pogo->kbd) {
		ret = stm32_pogo_register_kbd(pogo);
		if (ret)
			dev_err(&pogo->client->dev,
				"failed to register keyboard: %d\n", ret);
	}
	if (pogo->tp_present && !pogo->tp) {
		ret = stm32_pogo_register_tp(pogo);
		if (ret)
			dev_err(&pogo->client->dev,
				"failed to register touchpad: %d\n", ret);
	}
out:
	mutex_unlock(&pogo->dev_lock);
}

/* rail on, give the MCU 50 ms to boot, then let it drive ATTN */
static void stm32_pogo_start(struct stm32_pogo *pogo)
{
	int ret;

	if (pogo->started)
		return;

	ret = regulator_enable(pogo->vdd);
	if (ret) {
		dev_err(&pogo->client->dev, "failed to enable vddo: %d\n", ret);
		return;
	}
	msleep(50);

	pogo->started = true;
	pogo->handshaken = false;
	enable_irq(pogo->attn_irq);

	/*
	 * Watchdog: if the MCU has not completed the first exchange soon,
	 * declare the attach failed and power back down (downstream
	 * check_init_work). Without this a half-docked keyboard would hold
	 * the rail on forever.
	 */
	schedule_delayed_work(&pogo->init_work, msecs_to_jiffies(3000));
}

static void stm32_pogo_stop(struct stm32_pogo *pogo)
{
	if (!pogo->started)
		return;

	pogo->started = false;
	pogo->handshaken = false;
	disable_irq(pogo->attn_irq);
	cancel_delayed_work(&pogo->init_work);
	cancel_delayed_work(&pogo->ic_work);
	regulator_disable(pogo->vdd);
	stm32_pogo_unregister_inputs(pogo);
}

static void stm32_pogo_conn_work(struct work_struct *work)
{
	struct stm32_pogo *pogo = container_of(to_delayed_work(work),
					       struct stm32_pogo, conn_work);
	int state = gpiod_get_value(pogo->conn_gpio);

	mutex_lock(&pogo->dev_lock);
	dev_info(&pogo->client->dev, "conn: %d (started: %d)\n",
		 state, pogo->started);

	if (state)
		stm32_pogo_start(pogo);
	else
		stm32_pogo_stop(pogo);
	mutex_unlock(&pogo->dev_lock);
}

static void stm32_pogo_init_work(struct work_struct *work)
{
	struct stm32_pogo *pogo = container_of(to_delayed_work(work),
					       struct stm32_pogo, init_work);

	mutex_lock(&pogo->dev_lock);
	if (pogo->started && !pogo->handshaken) {
		dev_err(&pogo->client->dev, "handshake timed out, powering off\n");
		stm32_pogo_stop(pogo);
	}
	mutex_unlock(&pogo->dev_lock);
}

static irqreturn_t stm32_pogo_conn_isr(int irq, void *dev_id)
{
	struct stm32_pogo *pogo = dev_id;

	cancel_delayed_work(&pogo->conn_work);
	/* debounce detach; act on attach immediately */
	if (gpiod_get_value(pogo->conn_gpio))
		schedule_delayed_work(&pogo->conn_work, 0);
	else
		schedule_delayed_work(&pogo->conn_work, msecs_to_jiffies(250));

	return IRQ_HANDLED;
}

/* one ATTN service: header exchange, then payload dispatch */
static irqreturn_t stm32_pogo_attn_isr(int irq, void *dev_id)
{
	struct stm32_pogo *pogo = dev_id;
	u8 data[STM32_MAX_EVENT_SIZE] = { 0 };
	u8 hdr[3] = { 0 };
	u16 payload;
	int ret;

	if (gpiod_get_value(pogo->attn_gpio))
		return IRQ_HANDLED;

	mutex_lock(&pogo->i2c_lock);

	ret = stm32_pogo_header_write(pogo, pogo->led_ep, 0);
	if (ret < 0)
		goto out_unlock;

	ret = stm32_pogo_read(pogo, hdr, 3);
	if (ret < 0)
		goto out_unlock;

	payload = (hdr[1] << 8 | hdr[0]) - 3;

	if (!payload || payload > STM32_MAX_EVENT_SIZE) {
		/* first, empty exchange: the handshake itself */
		mutex_unlock(&pogo->i2c_lock);

		dev_info(&pogo->client->dev,
			 "handshake: keyboard model 0x%02x\n", hdr[2]);
		ret = stm32_pogo_read_version(pogo);
		if (ret < 0)
			dev_err(&pogo->client->dev,
				"failed to read version: %d\n", ret);
		pogo->handshaken = true;
		cancel_delayed_work(&pogo->init_work);
		schedule_delayed_work(&pogo->ic_work, msecs_to_jiffies(10));
		return IRQ_HANDLED;
	}

	ret = stm32_pogo_read(pogo, data, payload);
	if (ret < 0)
		goto out_unlock;

	mutex_unlock(&pogo->i2c_lock);

	switch (hdr[2]) {
	case STM32_EP_KEYPAD:
		stm32_pogo_keypad_event(pogo, data, payload);
		break;
	case STM32_EP_TOUCHPAD:
		/* MCU noise marker, downstream drops it too */
		if (payload >= 3 && data[0] == 0x03 && data[1] == 0x00 &&
		    data[2] == 0x05)
			break;
		stm32_pogo_touchpad_event(pogo, data, payload);
		break;
	case STM32_EP_HALL:
		/* cover folded/closed: release everything */
		dev_info(&pogo->client->dev, "hall event: %02x\n", data[0]);
		stm32_pogo_release_keys(pogo);
		stm32_pogo_release_fingers(pogo);
		break;
	case STM32_EP_ACCESSORY:
		dev_info(&pogo->client->dev, "accessory event: %02x %02x\n",
			 data[0], payload > 1 ? data[1] : 0);
		break;
	default:
		dev_warn(&pogo->client->dev, "unknown event ep %u len %u\n",
			 hdr[2], payload);
		break;
	}

	return IRQ_HANDLED;

out_unlock:
	mutex_unlock(&pogo->i2c_lock);
	return IRQ_HANDLED;
}

/* ------------------------------------------------------------- driver */

static int stm32_pogo_probe(struct i2c_client *client)
{
	struct stm32_pogo *pogo;
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
		return -ENXIO;

	pogo = devm_kzalloc(&client->dev, sizeof(*pogo), GFP_KERNEL);
	if (!pogo)
		return -ENOMEM;

	pogo->client = client;
	pogo->led_ep = 0x1;
	/* stock touchpad geometry; overridden by the MCU's own answer */
	pogo->tp_size_x = 1560;
	pogo->tp_size_y = 820;
	mutex_init(&pogo->i2c_lock);
	mutex_init(&pogo->dev_lock);
	INIT_DELAYED_WORK(&pogo->conn_work, stm32_pogo_conn_work);
	INIT_DELAYED_WORK(&pogo->init_work, stm32_pogo_init_work);
	INIT_DELAYED_WORK(&pogo->ic_work, stm32_pogo_ic_work);
	i2c_set_clientdata(client, pogo);

	pogo->vdd = devm_regulator_get(&client->dev, "vdd");
	if (IS_ERR(pogo->vdd))
		return dev_err_probe(&client->dev, PTR_ERR(pogo->vdd),
				     "failed to get vdd\n");

	pogo->conn_gpio = devm_gpiod_get(&client->dev, "conn", GPIOD_IN);
	if (IS_ERR(pogo->conn_gpio))
		return dev_err_probe(&client->dev, PTR_ERR(pogo->conn_gpio),
				     "failed to get conn gpio\n");

	pogo->attn_gpio = devm_gpiod_get(&client->dev, "attn", GPIOD_IN);
	if (IS_ERR(pogo->attn_gpio))
		return dev_err_probe(&client->dev, PTR_ERR(pogo->attn_gpio),
				     "failed to get attn gpio\n");

	pogo->nrst_gpio = devm_gpiod_get(&client->dev, "nrst", GPIOD_OUT_HIGH);
	if (IS_ERR(pogo->nrst_gpio))
		return dev_err_probe(&client->dev, PTR_ERR(pogo->nrst_gpio),
				     "failed to get nrst gpio\n");

	pogo->attn_irq = gpiod_to_irq(pogo->attn_gpio);
	pogo->conn_irq = gpiod_to_irq(pogo->conn_gpio);
	if (pogo->attn_irq < 0 || pogo->conn_irq < 0)
		return dev_err_probe(&client->dev, -EINVAL,
				     "failed to map gpio irqs\n");

	irq_set_status_flags(pogo->attn_irq, IRQ_NOAUTOEN);
	ret = devm_request_threaded_irq(&client->dev, pogo->attn_irq, NULL,
					stm32_pogo_attn_isr,
					IRQF_TRIGGER_LOW | IRQF_ONESHOT,
					"pogo-attn", pogo);
	if (ret)
		return dev_err_probe(&client->dev, ret,
				     "failed to request attn irq\n");

	ret = devm_request_threaded_irq(&client->dev, pogo->conn_irq, NULL,
					stm32_pogo_conn_isr,
					IRQF_TRIGGER_RISING |
					IRQF_TRIGGER_FALLING | IRQF_ONESHOT,
					"pogo-conn", pogo);
	if (ret)
		return dev_err_probe(&client->dev, ret,
				     "failed to request conn irq\n");

	/* already docked at boot? */
	if (gpiod_get_value(pogo->conn_gpio))
		schedule_delayed_work(&pogo->conn_work, 0);

	dev_info(&client->dev, "probed, conn=%d\n",
		 gpiod_get_value(pogo->conn_gpio));
	return 0;
}

static void stm32_pogo_remove(struct i2c_client *client)
{
	struct stm32_pogo *pogo = i2c_get_clientdata(client);

	disable_irq(pogo->conn_irq);
	cancel_delayed_work_sync(&pogo->conn_work);
	cancel_delayed_work_sync(&pogo->init_work);
	cancel_delayed_work_sync(&pogo->ic_work);

	mutex_lock(&pogo->dev_lock);
	stm32_pogo_stop(pogo);
	mutex_unlock(&pogo->dev_lock);
}

static const struct of_device_id stm32_pogo_of_match[] = {
	{ .compatible = "samsung,stm32-pogo" },
	{ }
};
MODULE_DEVICE_TABLE(of, stm32_pogo_of_match);

static const struct i2c_device_id stm32_pogo_id[] = {
	{ "stm32-pogo" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, stm32_pogo_id);

static struct i2c_driver stm32_pogo_driver = {
	.driver = {
		.name = "stm32-pogo",
		.of_match_table = stm32_pogo_of_match,
		.probe_type = PROBE_PREFER_ASYNCHRONOUS,
	},
	.probe = stm32_pogo_probe,
	.remove = stm32_pogo_remove,
	.id_table = stm32_pogo_id,
};
module_i2c_driver(stm32_pogo_driver);

MODULE_DESCRIPTION("Samsung pogo-pin Book Cover Keyboard driver");
MODULE_LICENSE("GPL");
