# Phase 12: sensors — what Linux can reach and what the SLPI keeps

Measurement record: issue #33. Inventory with citations:
`device-facts/sensor-survey-2026-09-21.md`. This page is the story of the
first sensor flash, kernel r26 on 2026-09-21.

## The inventory

Stock runs two sensor HALs. `sensors.ssc.so` talks to the SLPI, the
sensor DSP, which owns the motion and light sensors on its own I2C and
I3C ports. `sensors.grip.so` drives the two grip sensors from the
application processor over bit-banged I2C. Everything else that senses
is a switch or a thermistor.

| Function | Chip | Bus | Mainline driver | Reach |
|---|---|---|---|---|
| Accelerometer, gyroscope | ST LSM6DSO | SLPI I3C instance 1, 0x6b | st_lsm6dsx | SLPI only |
| Magnetometer | AKM AK09918 | SLPI I2C instance 2, 0x0c | ak8975 | SLPI only |
| Ambient light, colour | Vishay VEML3328 | SLPI I2C instance 4, 0x10 | veml3328 | SLPI only |
| Grip (SAR), two | Imagis ISG6320 | TLMM 186/187 and 175/176, 0x28 | none | AP |
| Hall, cover | switch | TLMM 169, active low | gpio-keys | AP |
| Hall, S Pen garage | switch | TLMM 23, active low | gpio-keys | AP |
| AP thermistor | NTC | pm8350 AMUX_THM1, ADC channel 0x144 | qcom-spmi-adc5 | AP |
| Wi-Fi thermistor | NTC | pm8350 gpio1, ADC channel 0x14a | qcom-spmi-adc5 | AP |

There is no barometer and no proximity sensor. Mainline has IIO drivers
for all three SLPI chips; what it lacks is a way onto their buses.

## What the SLPI work already established

The SLPI boots under mainline with the stock firmware and stays up
(PR #23). The five island pads the stock hub drives, TLMM 184, 185,
188, 189 and 202, are known from the microphone hunt, where driving
them high changed nothing for the mics. The rooted stock session of
2026-09-21 showed the hub's two rails, pm8350c L2C at 1.8 V and L13C at
3.0 V, drop when the SLPI stops. Nobody has traced the sensor traffic
itself: which pad pair carries which bus, and the QMI registry exchange
the hub needs before it publishes a sensor. That exchange is what stock's
`sscrpcd` does, and no mainline or postmarketOS component does it.

## First flash: hall switches and thermistors (r26)

The two hall switches join the `gpio-keys` node as EV_SW switches,
`SW_MACHINE_COVER` on TLMM 169 and `SW_PEN_INSERTED` on TLMM 23, both
wakeup sources, with a TLMM pin state matching the stock `hall_irq` and
`hall_wacom_irq` nodes. The thermistors are two channels on the pmk8350
ADC, `PM8350_ADC7_AMUX_THM1_100K_PU(1)` and
`PM8350_ADC7_GPIO1_100K_PU(1)`, ratiometric with a 200 µs settle as the
SM8450 HDK declares its thermistors, plus a pm8350 GPIO state that puts
gpio1 in high impedance for the analog input.

On the tablet, `gpio-keys` is input5 and reports both switches; at rest
in the keyboard dock the cover reads open and the pen reads inserted.
`iio:device0` gains `in_temp_ap_therm_input` and
`in_temp_wf_therm_input`. Readings at idle:

| Channel | mainline | nearby zones |
|---|---|---|
| ap_therm | 31 to 36 °C | CPU tsens 33 to 34 °C, PMIC die 37 °C |
| wf_therm | 62 to 67 °C | Wi-Fi idle |

The AP value sits with its neighbours. The Wi-Fi value does not: stock
converts each thermistor with its own microvolt table
(`sec_thermistor` `adc_array`/`temp_array`, different curves for the
two parts), while mainline applies its generic NTCG104EF104 table to
both pull-up channels. Until that table is reproduced in userspace or
the channel declared with the right scale, `wf_therm` is a trend, not a
temperature. The switches did not toggle under handling: the operator
took the pen off and on and folded the cover while a query loop and
then evtest watched input5, and neither switch changed state. The S Pen
line did count two edges in `/proc/interrupts` across the session, the
cover line none. Both pads read the same levels stock reads at idle
(TLMM 23 low, 169 high, no pull, 2 mA), so the mapping is right and the
sensors are powered; what the magnets do to the pads is the open
question, recorded on issue #33.

## Next

The motion, magnetometer and light sensors go through the SLPI, and
postmarketOS already ships the stack other Qualcomm ports use for it:
`hexagonrpcd` answers the SLPI's FastRPC file requests from a HexagonFS
tree (the stock `/vendor/etc/sensors` configuration), `libssc` speaks
the `sns_client` QMI service over QRTR, and `iio-sensor-proxy` has a
libssc backend. The Fairphone 4 and SHIFT axolotl ports run exactly
this. For this tablet it takes `CONFIG_FASTRPC`, the SLPI's fastrpc
child already in `sm8450.dtsi`, a HexagonFS package built from the
vendor dump's sensor configuration, and the two rails the hub expects
(pm8350c L2C and L13C) declared. If the SLPI asks for files the dump
lacks, hexagonrpcd logs the paths; that is the moment a stock session
to copy the persist registry would pay off. The grip sensors have no
driver and little use on a tablet.
