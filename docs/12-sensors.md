# Phase 12: sensors — what Linux can reach and what the SLPI keeps

Measurement record: issue #33. Inventory with citations:
`device-facts/sensor-survey-2026-09-21.md`. This page is the story of the
sensor flashes: kernel r26 on 2026-09-21 for the hall switches and
thermistors, r27 and r28 on 2026-09-22 for the SLPI.

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
`in_temp_wf_therm_input`. Readings at idle, with the same ADC codes put
through stock's own tables:

| Channel | mainline | stock table | nearby zones |
|---|---|---|---|
| ap_therm | 31.2 to 36.3 °C | 25.3 to 30.1 °C | CPU tsens 33 to 34 °C, PMIC die 37 °C |
| wf_therm | 62.1 to 67.4 °C | 60.0 to 65.1 °C | Wi-Fi idle |

Mainline converts both channels with its generic NTCG104EF104 table
(`adcmap7_100k`, resistance against a 100k pull-up). Stock reads each
channel as microvolts at the ADC's default scale, code × 1875000 /
0x70e4, and maps them through a per-thermistor table in its device tree
(`sec_thermistor` `adc_array`/`temp_array`). Through those tables the
Wi-Fi thermistor reads 60 to 65 °C, within 2 °C of mainline, so it is
warm rather than miscalibrated. The AP thermistor is the one that
differs: mainline's generic curve reads about 5 °C above stock's table
for that part. `gts8pwifi-therm` in the device package inverts mainline's
conversion back to the ADC code and prints both temperatures for each
channel (`--json` for scripts, `--convert LABEL MDEGC` for a single
value). The switches did not toggle under handling: the operator
took the pen off and on and folded the cover while a query loop and
then evtest watched input5, and neither switch changed state. The S Pen
line did count two edges in `/proc/interrupts` across the session, the
cover line none. Both pads read the same levels stock reads at idle
(TLMM 23 low, 169 high, no pull, 2 mA), so the mapping is right and the
sensors are powered; what the magnets do to the pads is the open
question, recorded on issue #33. A second session on 2026-09-22 gave the
same result: the folio closed and reopened three times and the pen swept
over the back and edges as a moving magnet left both edge counters where
they were. Stock's boot-time dump shows the same idle levels, so the
hall ICs may sit on a rail mainline leaves off, which is the next thing
to test. That session ended in a silent hang right after a minute of
polling `/sys/kernel/debug/gpio` at 5 Hz, a listing that also walks the
LPASS island pin controller; the interrupt counters are the safe view.

## The SLPI route (r27, r28)

The route the previous section planned was walked on 2026-09-22. The
SLPI had been booting with the stock firmware since PR #23, and QRTR
service 400, the Snapdragon Sensor Core, sat on the bus and answered
nothing. `hexagonrpcd` 0.4.0 from Alpine, attached to `/dev/fastrpc-sdsp`
and serving the stock `/vendor/etc/sensors` tree, showed in its journal
what the hub was waiting for:

| Request from the SLPI | What 0.4.0 did |
|---|---|
| `/sys/class/sensors/ssc_core/ssc_hw_rev`, the Samsung sysfs path named in `sns_reg_config` | no such file |
| an AP-side FastRPC interface `sns_registry` | "Could not find local interface sns_registry" |
| writes to `sns_reg_version` and `temp.json` in the registry's parent directory | "Tried to open ... for writing", refused |

The revision path was the easy one: point that line at
`/sys/devices/soc0/ssc_hw_rev` and serve "4", the Android `ro.revision`.
The refused writes were retried once per second, and each retry produced
the once-per-second kernel line `qcom_q6v5_pas 2400000.remoteproc:
Handover signaled, but it already happened`. Pre-generating the registry
with upstream's `tools/sscregistrygen` changed nothing: the hub writes
its own.

The fix is `hexagonrpcd` from upstream main 598b591 with seven patches.
Five are upstream PR #26, write support for mapped directories and the
registry's parent. One adds the `sns_registry` local interface: handle
3, method 0, `get_property(name) -> value`, layout taken from
disassembling the stock `libsns_registry_skel.so`. Live, the SLPI asks
it for one property, `ro.revision`, four times, and only while
regenerating the registry. The last patch line-buffers stdout. With the
patched daemon the SLPI wrote `sns_reg_version`, wrote `temp.json` and
renamed it into the registry 208 times for 141 groups, read everything
back, and on later boots writes nothing.

With the registry complete, the sensor process crashed 13 s after every
SLPI boot, 6 of 6:

```
sns_com_port_i2c.c:241 ... status != I2C_ERROR_TRANSFER_TIMEOUT
```

The two rails the stock SLPI remoteproc node holds, pm8350c L2C
(`sensor_vdd`, 1.8 V) and L13C (`sensor_vddio`, 3.0 V), were undeclared
on mainline. The mainline SLPI node has no supply properties, so kernel
r27 declares both always-on in the board DTS. With them, 60 s after an
SLPI restart, no crash, and `ssccli` read the sensors. Tablet landscape
in the keyboard dock, screen tilted back, dim room:

| Sensor | Reading |
|---|---|
| accelerometer | X 8.45, Y -0.18, Z 5.03 m/s² |
| light | 6 lux |
| magnetometer | X 33, Y 227, Z -17 µT, uncalibrated |

Once initialised the SLPI keeps serving without the daemon.

`iio-sensor-proxy` 3.9 from Alpine, with its libssc backend, found the
accelerometer, light and compass and attaches them to
`/dev/fastrpc-adsp`. The mount matrix came from measuring with the
identity matrix:

| Pose | Raw accelerometer | Reported |
|---|---|---|
| flat, screen up | 0, -0.2, +9.8 | face-up |
| landscape, camera edge up | +9.9, -0.2, -0.9 | left-up |
| portrait, camera right | 0.1, +9.8, -0.7 | bottom-up |

The panel is landscape-native (2800x1752, no rotation), so camera edge
up has to be "normal". `ACCEL_MOUNT_MATRIX="0, 1, 0; -1, 0, 0; 0, 0, 1"`
on the `fastrpc-*` misc devices does it. With it `monitor-sensor` in the
dock reports orientation normal, tilt tilted-up, light 6 lux and a
compass heading of about 340°.

Packaging. `pmaports-overlay/temp/hexagonrpcd` is the Alpine aport as a
git snapshot, version 0.5.0_git20260824, with the seven patches; it also
installs `sscregistrygen`, which upstream builds and does not install.
Same pkgname and a higher version than Alpine's, so apk prefers it; it
goes away when a release carries the patches. The device package, r24,
depends on `hexagonrpcd`, `libssc`, `iio-sensor-proxy`,
`make-dynpart-mappings` and `device-mapper`. Its `-systemd` subpackage
pulls in `hexagonrpcd-systemd` and a udev rule,
`90-gts8pwifi-hexagonrpcd-sdsp.rules`, that starts
`hexagonrpcd-sdsp.service` when `/dev/fastrpc-sdsp` appears; the unit's
own path condition is evaluated before the SLPI boots and a failed
condition is not retried. The mount matrix ships as
`81-libssc-samsung-gts8pwifi.rules`.

No proprietary file enters the repo. `gts8pwifi-fw-extract` maps the
tablet's own `super` partition read-only with `make-dynpart-mappings`,
mounts the vendor F2FS read-only, and copies `/vendor/etc/sensors` into
`/usr/share/qcom/sm8450/Samsung/gts8pwifi/`: the config JSONs,
`sns_reg.conf` with the revision line fixed, a `socinfo/` directory
served as `/sys/devices/soc0`, and a registry pre-generated with
`sscregistrygen`. An existing registry is left alone; it holds the
SLPI's own state.

The tablet still carries the stock `persist` partition (ext4, label
"persist"). Mounted read-only, `sensors/registry/registry/` holds the
registry the stock hub ran with, 178 files: the same 141 groups the SLPI
generates from the configs, with this unit's factory calibration filled
in (the magnetometer's soft-iron matrix in `ak0991x_0_platform.mag.fac_cal.corr_mat`,
Samsung's axis orientation, `-y,+x,+z` for the accelerometer in
`lsm6dso_0_platform.orient` and `+x,+y,+z` for the magnetometer in
`ak0991x_0_platform.orient`, in place of the MTP reference), plus the
calibration state the hub saved at runtime: 27 `sns_gyro_cal_table_s0.*`
files and the magnetometer bias in `sns_mag_cal_persist_s0c0`.
`gts8pwifi-fw-extract` now copies that directory into the served
registry when it is empty (or on `--refresh-registry`) and removes the
stale `sns_reg_version` so the SLPI re-validates it; the `sscregistrygen`
registry is the fallback when persist is missing or empty. Measured
with the stock registry installed and the SLPI restarted, the raw
accelerometer in the dock reads 8.44, -0.20, 5.06 m/s², the same frame
as with the generated registry: the stock registry's orient entries do
not change the frame libssc reports, and the mount matrix measured above
stays. The magnetometer did change with it, from X 33, Y 227, Z -17 µT
in the dock to X 89, Y 260, Z -66 µT, which shows the factory correction
matrix is applied.

The vendor image is F2FS with LZ4 compression, which
needs `CONFIG_F2FS_FS_COMPRESSION` and `CONFIG_F2FS_FS_LZ4`, which kernel
r28 carries. Verified on r28 in one boot: the udev rule started the
packaged daemon with no retry loop, `gts8pwifi-fw-extract` mapped super,
mounted vendor and rebuilt the 66 configs, socinfo and `sns_reg.conf`
from the tablet's own copy, and iio-sensor-proxy reported orientation
normal in the dock. Restarting the daemon while the SLPI runs breaks its
FastRPC session, and the SLPI re-negotiates it with a burst of
"Handover signaled" kernel lines; the extractor therefore leaves the
daemon alone, since the SLPI reads the tree only at its own boot. `tools/sensors-from-super.sh`
is the host fallback: it unpacks vendor from a `super.img` dump, copies
the sensor tree and hands it to `gts8pwifi-fw-extract --sensors-from`
over ssh.

## Next

- Gyroscope: libssc exposes accelerometer, light, magnetometer and
  proximity; the LSM6DSO's gyroscope is not yet read.
- Send the `sns_registry` patch and the write support upstream to
  linux-msm/hexagonrpc (PR #26 is the write half).
- Hall switches: why the magnets did not toggle the pads under handling.
