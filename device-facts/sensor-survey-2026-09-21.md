# Sensor survey: SM-X800 (Galaxy Tab S8+, SM8450), 2026-09-21

Read-only inventory of the motion, environmental and proximity-class sensors and how each can be reached from mainline Linux 7.2 (postmarketOS). Sources: the stock DT dump at `/home/aaron/src/sm8450-camera-ref/vendor/dt/stock-fdt.dts`, the stock vendor image dump under `/home/aaron/src/sm8450-camera-ref/vendor/fulldump/vendor/`, the rooted stock runtime captures under `device-facts/stock-runtime/`, the board DTS at `pmaports-overlay/device/testing/linux-postmarketos-qcom-sm8450/sm8450-samsung-gts8pwifi.dts`, and mainline 7.2 at `patch-work/linux-7.2`. Paths below are relative to those roots unless absolute.

## Inventory

Stock runs two sensor HALs (`vendor/etc/sensors/hals.conf`): `sensors.ssc.so` for the SLPI sensor hub and `sensors.grip.so` for the AP-side grip sensors. The stock sensorservice dump (`device-facts/stock-runtime/2026-09-18/sensorservice.txt` lines 15, 17, 19, 21, 55, 57, 59) names the chips. No barometer and no proximity sensor exist. The stock AP I2C client list (`stock-runtime/2026-09-18/i2c-devices.txt` lines 1 to 22) contains only two sensor-class devices: the ISG6320 grip chips.

### SLPI-owned sensors (hard path)

| Function | Chip | Bus and address (SSC registry) | IRQ pin | Supply | Mainline driver |
|---|---|---|---|---|---|
| Accel + gyro | ST LSM6DSO | SSC bus_type 3 (I3C SDR in the SEE enum, not verified against a header here), bus_instance 1, addr 0x6b (107), I3C dynamic addr 0x0a | TLMM 15 (`dri_irq_num` 7798799 = 0x77000F; the HDK sibling config uses plain 15) | `/pmic/client/sensor_vddio` | `st_lsm6dsx`, `st,lsm6dso` (`drivers/iio/imu/st_lsm6dsx/st_lsm6dsx_i2c.c:66`, `_spi.c:61`, `_i3c.c` present) |
| Magnetometer | AKM AK09918 | SSC bus_type 0 (I2C), bus_instance 2, addr 0x0c (12) | TLMM 89 | `/pmic/client/sensor_vddio` | `ak8975`, `asahi-kasei,ak09918` (`drivers/iio/magnetometer/ak8975.c:1155`) |
| Ambient light / CCT | Vishay VEML3328 | SSC bus_type 0 (I2C), bus_instance 4, addr 0x10 (16) | none (`dri_irq_num` absent) | `dummy_vdd` both rails | `veml3328`, `vishay,veml3328` (`drivers/iio/light/veml3328.c:398`) |

Registry sources: `vendor/etc/sensors/config/waipio_lsm6dso_0_0.json` lines 11 to 25 and 54 to 56; `waipio_ak991x_0.json` lines 44 to 87 (`_3` and `_4` differ only in `ro.revision` selectors and mag soft-iron matrices; this tablet is `ro.revision` 4 per `device-facts/getprop-full.txt`, so `waipio_ak991x_4.json` applies); `waipio_veml3328_0.json` lines 11 to 38. The filters match `soc_id` 457 (SM8450).

Physical pins of SSC bus instances 1, 2 and 4: not found in the AP device tree. Five candidate pads are known from prior work: TLMM 184, 185, 188, 189 and 202 (`docs/10-audio.md` lines 159 to 163). Stock leaves them AP-unclaimed (`stock-runtime/2026-09-18/00-idle/pinmux-f000000.pinctrl.txt` lines 187 to 205), pulled down but reading high at idle (`gpio.txt` lines 247 to 265), and mainline marks all five `egpio` (`drivers/pinctrl/qcom/pinctrl-sm8450.c:1597-1615`). IRQ pins 15 and 89 are AP-unclaimed inputs, pulled down, low (`pinmux` lines 18 and 92, `gpio.txt` lines 82 and 152). Pad-to-bus mapping is not established.

Rails: the stock SLPI node requests `sensor_vdd` = pm8350c L2C 1.8 V and `sensor_vddio` = pm8350c L13C 3.0 V (`stock-fdt.dts:6773-6788`; regulators at lines 11316 to 11325 and 11519 to 11527). Both drop when the SLPI stops (`stock-runtime/2026-09-21/dmesg.txt:1462-1463`).

### AP-reachable sensors (easy path)

| Function | Chip | Bus and address | IRQ | Supply | Mainline driver |
|---|---|---|---|---|---|
| Grip / SAR (main) | Imagis ISG6320 | stock `i2c-gpio` `i2c@55`, SDA TLMM 186, SCL TLMM 187, 100 kHz, addr 0x28 | TLMM 182 | LDO enable TLMM 180 driven high; regulator node not found | none |
| Grip / SAR (sub) | Imagis ISG6320 | stock `i2c-gpio` `i2c@57`, SDA TLMM 175, SCL TLMM 176, addr 0x28 | TLMM 116 | same LDO enable | none |
| Grip for Wi-Fi | Semtech, model not found | not found (no DT node, no AP I2C client) | not found | not found | `sx9310`, `sx9324`, `sx9360` exist; chip unidentified |
| Hall: cover | GPIO hall switch | TLMM 169, active low, stock event code 0x15 | TLMM 169 edge | none | `gpio-keys`, `SW_MACHINE_COVER` (0x10, `include/uapi/linux/input-event-codes.h:953`) |
| Hall: S Pen attach | GPIO hall switch | TLMM 23, active low, stock event code 0x1e | TLMM 23 edge | none | `gpio-keys`, `SW_PEN_INSERTED` (0x0f, line 952) |
| AP thermistor | NTC on PMIC ADC | pmk8350 VADC channel 0x144 = `PM8350_ADC7_AMUX_THM1_100K_PU(1)` | n/a | n/a | `qcom-spmi-adc5` (`CONFIG_QCOM_SPMI_ADC5=y`, `sm8450.config:133`) |
| Wi-Fi thermistor | NTC on PMIC ADC | pmk8350 VADC channel 0x14a = PM8350 sid 1 `ADC7_GPIO1_100K_PU`, PMIC gpio1 high-impedance | n/a | n/a | same |

Sources: grip buses `stock-fdt.dts:36248-36335`, grip pinctrl lines 5458 to 5565, stock IRQ counts `stock-runtime/2026-09-18/00-idle/interrupts.txt:290-291`; grip HAL device names from `strings vendor/lib64/sensors.grip.so` (`/dev/grip_sensor_wifi`, vendor string `SEMTECH`); hall node `stock-fdt.dts:35926-35944`, pinctrl lines 5250 to 5278, stock IRQs `interrupts.txt:237-238`; thermistors `stock-fdt.dts:36009-36037`; ADC channel defines `include/dt-bindings/iio/qcom,spmi-vadc.h:266-272`. Stock event codes 0x15 and 0x1e are Samsung extensions above mainline `SW_MAX` (0x11).

## SLPI state on mainline

- Firmware present and signed for this device. `pmaports-overlay/device/testing/device-samsung-gts8pwifi/fw-extract.sh` lines 48 to 56 stage `slpi.mdt` and `slpi.b*` from `apnhlos/image`. PR #23 reports it boots under TrustZone PAS and stays up, so the signature check passes. `docs/09-firmware-harvest.md` does not list it.
- Board DTS enables it: `sm8450-samsung-gts8pwifi.dts:1768-1775`, stock carve-out 0x88000000 size 0x1700000.
- Mainline node: `sm8450.dtsi:2705-2770` (`qcom,sm8450-slpi-pas`, `qcom_q6v5_pas.c:1641`), `fastrpc` child labelled `sdsp` on `fastrpcglink-apps-dsp` with three compute context banks; `smp2p-slpi` at lines 904 to 926. The mainline resource init does not take the stock `sensor_vdd` and `sensor_vddio` rails.
- Kernel config: `pmos.config` has `QCOM_Q6V5_PAS`, `QRTR`, `QRTR_SMD`, `I2C_GPIO`, `KEYBOARD_GPIO`; `sm8450.config` has `RPMSG_CHAR`, `QCOM_SPMI_ADC5`. Neither fragment sets `CONFIG_FASTRPC` or any `CONFIG_IIO` option.
- Why nothing is exposed: README line 55 and the DTS comment at lines 1760 to 1767. The hub waits for its registry, which stock's `sscrpcd` feeds over QMI (`dmesg.txt:1255` names `msm/slpi/sensor_pd` as the fastrpc protection domain). That stack (`libssc.so`, `libsnsapi.so`, `sensors.ssc.so`, registry at `/mnt/vendor/persist/sensors/registry` per `sns_reg_config` line 8) is not mainline, and the persist registry is not in the dump.

## Flags

- No board-DTS pin conflicts. TLMM 15, 23, 89, 116, 169, 175, 176, 180, 182, 184 to 189 and 202 appear nowhere in the board DTS. The `i2c-gpio` precedent is the Wacom bus on TLMM 52/53 at lines 1540 to 1549.
- Sensor rails are undeclared on mainline. L2C and L13C have no node in the board DTS; `docs/10-audio.md` lines 134 to 136 and 168 to 172 record always-on experiments added and reverted. Any direct-bus attempt at the IMU, magnetometer or ALS needs L13C declared.
- Direct AP access to the SLPI sensors is speculative. The five egpio pads can be muxed to TLMM, so a bit-banged bus to the AK09918 (0x0c) and VEML3328 (0x10) is conceivable, and the LSM6DSO answers I2C at 0x6b before I3C dynamic addressing. The pad-to-bus mapping is unknown, and driving those pads with the SLPI booted would fight the hub. A pad probe with `tools/padsample.py` on stock, or the SLPI left disabled, comes first.
- ISG6320 has no mainline driver. The Semtech Wi-Fi grip chip is unidentified in every source.

## Recommended first step

Land the two sensor classes that need no new driver and no SLPI: the hall switches and the thermistors.

Hall switches, added to the `gpio-keys` node at `sm8450-samsung-gts8pwifi.dts:313`, with a `&tlmm` pinctrl state `pins = "gpio169", "gpio23"; function = "gpio"; bias-disable` matching `stock-fdt.dts:5253-5278`:

```dts
cover {
	label = "Cover";
	gpios = <&tlmm 169 GPIO_ACTIVE_LOW>;
	linux,input-type = <EV_SW>;
	linux,code = <SW_MACHINE_COVER>;
	wakeup-source;
};
pen-insert {
	label = "S Pen";
	gpios = <&tlmm 23 GPIO_ACTIVE_LOW>;
	linux,input-type = <EV_SW>;
	linux,code = <SW_PEN_INSERTED>;
	wakeup-source;
};
```

Thermistors, following `sm8450-hdk.dts:782-796`, plus a `&pm8350_gpios` state for gpio1 with `function = "normal"; bias-high-impedance` per `stock-fdt.dts:12586-12590`:

```dts
&pmk8350_vadc {
	channel@144 {
		reg = <PM8350_ADC7_AMUX_THM1_100K_PU(1)>;
		qcom,ratiometric;
		qcom,hw-settle-time = <200>;
		label = "ap_therm";
	};
	channel@14a {
		reg = <PM8350_ADC7_GPIO1_100K_PU(1)>;
		qcom,ratiometric;
		qcom,hw-settle-time = <200>;
		label = "wf_therm";
	};
};
```

That yields lid-close and pen-attach events on evdev and two IIO temperature channels with the config already built. The hard path after that is a userspace QRTR client for the SLPI's `sns_client` QMI service, which nothing in pmOS provides today.
