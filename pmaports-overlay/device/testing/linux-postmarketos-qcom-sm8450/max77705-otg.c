// SPDX-License-Identifier: GPL-2.0-only
/*
 * MAX77705 OTG VBUS boost — minimal regulator driver.
 *
 * The MAX77705 Samsung companion PMIC owns Type-C, charging and VBUS on
 * this tablet. This driver exposes exactly one capability: the charger
 * block's OTG 5 V boost, as a regulator, so the tablet can power
 * bus-powered USB peripherals in host mode. Everything else the chip
 * does (charging policy, fuel gauge, MUIC, PD) is left untouched — the
 * charger keeps doing its autonomous thing.
 *
 * Mode transitions mirror the downstream max77705_charger.c state
 * machine (CHG_CNFG_00 mode nibble): OTG-on ADDS the boost to whatever
 * buck/charge state is active (0x4 -> 0xE, 0x5 -> 0xF), it does not
 * replace it — mode 0xA (boost+OTG only) would drop the system buck.
 * Verified live on-device before this driver existed: a single 0x05 ->
 * 0x0F write powered and enumerated a bus-powered HID device.
 *
 * Enable refuses with -EBUSY while a charger input is present
 * (CHG_INT_OK bit 6): the boost drives the same VBUS pins the charger
 * feeds from, and that contention must be resolved by a future Type-C
 * port manager, not by hoping.
 *
 * This is deliberately NOT a port of the downstream charger driver and
 * will be retired if/when the mainline max77705 MFD series is
 * backported.
 */

#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/driver.h>
#include <linux/regulator/of_regulator.h>

#define MAX77705_CHG_INT_OK		0xb2
#define MAX77705_CHGIN_OK		BIT(6)

#define MAX77705_CHG_CNFG_00		0xb7
#define MAX77705_MODE_MASK		GENMASK(3, 0)

#define MAX77705_CHG_CNFG_02		0xb9
#define MAX77705_OTG_ILIM_MASK		GENMASK(7, 6)
#define MAX77705_OTG_ILIM_900		(0x1 << 6)

#define MAX77705_CHG_CNFG_06		0xbd
#define MAX77705_CHGPROT_MASK		GENMASK(3, 2)
#define MAX77705_CHGPROT_UNLOCK		(0x3 << 2)

/* CHG_CNFG_00 mode nibble values (downstream max77705_charger.h) */
#define MODE_ALL_OFF			0x0
#define MODE_BUCK_ON			0x4
#define MODE_BUCK_CHG_ON		0x5
#define MODE_BOOST_OTG_ON		0xa
#define MODE_BUCK_BOOST_OTG_ON		0xe
#define MODE_BUCK_CHG_BOOST_OTG_ON	0xf

struct max77705_otg {
	struct i2c_client *client;
	struct regulator_dev *rdev;
};

static int max77705_otg_update_mode(struct max77705_otg *otg, bool enable)
{
	int val, mode, new_mode;

	val = i2c_smbus_read_byte_data(otg->client, MAX77705_CHG_CNFG_00);
	if (val < 0)
		return val;

	mode = val & MAX77705_MODE_MASK;

	if (enable) {
		switch (mode) {
		case MODE_ALL_OFF:
			new_mode = MODE_BOOST_OTG_ON;
			break;
		case MODE_BUCK_ON:
			new_mode = MODE_BUCK_BOOST_OTG_ON;
			break;
		case MODE_BUCK_CHG_ON:
			new_mode = MODE_BUCK_CHG_BOOST_OTG_ON;
			break;
		case MODE_BOOST_OTG_ON:
		case MODE_BUCK_BOOST_OTG_ON:
		case MODE_BUCK_CHG_BOOST_OTG_ON:
			return 0;
		default:
			/* charger is in a state we don't model; do not guess */
			dev_warn(&otg->client->dev,
				 "unexpected charger mode 0x%x, refusing OTG\n",
				 mode);
			return -EINVAL;
		}
	} else {
		switch (mode) {
		case MODE_BOOST_OTG_ON:
			new_mode = MODE_ALL_OFF;
			break;
		case MODE_BUCK_BOOST_OTG_ON:
			new_mode = MODE_BUCK_ON;
			break;
		case MODE_BUCK_CHG_BOOST_OTG_ON:
			new_mode = MODE_BUCK_CHG_ON;
			break;
		default:
			return 0;
		}
	}

	return i2c_smbus_write_byte_data(otg->client, MAX77705_CHG_CNFG_00,
					 (val & ~MAX77705_MODE_MASK) | new_mode);
}

static int max77705_otg_enable(struct regulator_dev *rdev)
{
	struct max77705_otg *otg = rdev_get_drvdata(rdev);
	int val;

	val = i2c_smbus_read_byte_data(otg->client, MAX77705_CHG_INT_OK);
	if (val < 0)
		return val;
	if (val & MAX77705_CHGIN_OK) {
		dev_err(&otg->client->dev,
			"charger input present, not enabling OTG boost\n");
		return -EBUSY;
	}

	return max77705_otg_update_mode(otg, true);
}

static int max77705_otg_disable(struct regulator_dev *rdev)
{
	struct max77705_otg *otg = rdev_get_drvdata(rdev);

	return max77705_otg_update_mode(otg, false);
}

static int max77705_otg_is_enabled(struct regulator_dev *rdev)
{
	struct max77705_otg *otg = rdev_get_drvdata(rdev);
	int val;

	val = i2c_smbus_read_byte_data(otg->client, MAX77705_CHG_CNFG_00);
	if (val < 0)
		return val;

	switch (val & MAX77705_MODE_MASK) {
	case MODE_BOOST_OTG_ON:
	case MODE_BUCK_BOOST_OTG_ON:
	case MODE_BUCK_CHG_BOOST_OTG_ON:
		return 1;
	default:
		return 0;
	}
}

static const struct regulator_ops max77705_otg_ops = {
	.enable = max77705_otg_enable,
	.disable = max77705_otg_disable,
	.is_enabled = max77705_otg_is_enabled,
};

static const struct regulator_desc max77705_otg_desc = {
	.name = "max77705-otg-vbus",
	.of_match = of_match_ptr("otg-vbus"),
	.ops = &max77705_otg_ops,
	.type = REGULATOR_VOLTAGE,
	.owner = THIS_MODULE,
	.n_voltages = 1,
	.fixed_uV = 5100000,
};

static int max77705_otg_probe(struct i2c_client *client)
{
	struct regulator_config config = { };
	struct max77705_otg *otg;
	int ret;

	otg = devm_kzalloc(&client->dev, sizeof(*otg), GFP_KERNEL);
	if (!otg)
		return -ENOMEM;

	otg->client = client;
	i2c_set_clientdata(client, otg);

	/*
	 * Downstream init: unlock the protected charger registers and cap
	 * the OTG boost at 900 mA. Both were already factory-set on this
	 * device; writing them is belt and braces, not a change.
	 */
	ret = i2c_smbus_read_byte_data(client, MAX77705_CHG_CNFG_06);
	if (ret < 0)
		return dev_err_probe(&client->dev, ret, "charger not reachable\n");
	i2c_smbus_write_byte_data(client, MAX77705_CHG_CNFG_06,
				  (ret & ~MAX77705_CHGPROT_MASK) |
				  MAX77705_CHGPROT_UNLOCK);

	ret = i2c_smbus_read_byte_data(client, MAX77705_CHG_CNFG_02);
	if (ret >= 0)
		i2c_smbus_write_byte_data(client, MAX77705_CHG_CNFG_02,
					  (ret & ~MAX77705_OTG_ILIM_MASK) |
					  MAX77705_OTG_ILIM_900);

	config.dev = &client->dev;
	config.driver_data = otg;

	otg->rdev = devm_regulator_register(&client->dev, &max77705_otg_desc,
					    &config);
	if (IS_ERR(otg->rdev))
		return dev_err_probe(&client->dev, PTR_ERR(otg->rdev),
				     "failed to register regulator\n");

	dev_info(&client->dev, "OTG VBUS boost regulator registered\n");
	return 0;
}

static const struct of_device_id max77705_otg_of_match[] = {
	{ .compatible = "samsung,max77705-otg" },
	{ }
};
MODULE_DEVICE_TABLE(of, max77705_otg_of_match);

static const struct i2c_device_id max77705_otg_id[] = {
	{ "max77705-otg" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, max77705_otg_id);

static struct i2c_driver max77705_otg_driver = {
	.driver = {
		.name = "max77705-otg",
		.of_match_table = max77705_otg_of_match,
	},
	.probe = max77705_otg_probe,
	.id_table = max77705_otg_id,
};
module_i2c_driver(max77705_otg_driver);

MODULE_DESCRIPTION("MAX77705 OTG VBUS boost regulator");
MODULE_LICENSE("GPL");
