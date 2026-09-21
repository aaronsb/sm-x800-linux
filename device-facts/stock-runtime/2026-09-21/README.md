# Stock Android runtime capture, 2026-09-21

Rooted stock Android 15 on the SM-X800 (gts8pwifi). Build `X800XXU9DYDC`, kernel `5.10.226-00182-g956d73ce2904`, Android `AP3A.240905.015.A2` (same build as `../2026-09-18/stock-build.txt` lines 1 to 3; no build file was taken this session). Root through KernelSU per `runbooks/stock-android-audio-capture/README.md`. The session answers two follow-ups to GitHub issue #7 and one camera question: does the sensor hub (SLPI) have to run for the microphones to work, what do the DMIC pads do at pad level on stock, and what camera and flash hardware the vendor kernel reports.

The device clock was not synchronised. Every `when.txt` says `Tue Apr 15 2025`. The host date for the session was 2026-09-21.

## What was captured

Two snapshot sets, both taken with scripts from `runbooks/stock-android-audio-capture/` copied to `/data/local/tmp/` on the device:

- `hal/` from `fastsnap.sh`, the same reads as the 2026-09-18 set.
- `cam/` from `camsnap.sh`, first used this session: Samsung camera sysfs, the LED class, the camera HAL dump, the vendor camera file lists, camera dmesg lines, I2C devices, remoteproc states.

| Directory | State | How the state was produced |
|---|---|---|
| `hal/00-idle`, `cam/00-idle` | home screen, SLPI running | none. `cam/00-idle/remoteproc.txt` line 4: `remoteproc3 2400000.remoteproc-slpi running` |
| `cam/06-torch` | rear torch on | `camsnap.sh 06-torch torch`. `cam/06-torch/torch.txt` lines 1 and 2: `1` then `0` written to `/sys/class/camera/flash/rear_flash`, the reads in between. The operator saw the light go on and off. |
| `hal/07-slpi-off-recording`, `cam/07-slpi-off-recording` | SLPI stopped, camera app recording video | `echo stop > /sys/class/remoteproc/remoteproc3/state`, then `com.sec.android.app.camera` in video mode, Record tapped. `cam/07-slpi-off-recording/remoteproc.txt` line 4: `remoteproc3 2400000.remoteproc-slpi offline`. `cam/07-slpi-off-recording/ps.txt` line 22: `com.sec.android.app.camera` pid 18187. |

There is no `01` to `05` state this session. The numbering continues from the 2026-09-18 set so the two sessions do not collide. There is no idle-after snapshot.

Snapshot times (`when.txt`, device clock): `hal/00-idle` 06:22:47, `cam/00-idle` 06:22:49, `cam/06-torch` 06:23:08, `hal/07-slpi-off-recording` 06:25:04, `cam/07-slpi-off-recording` 06:25:05.

Per-state files under `hal/`:

| File | Source |
|---|---|
| `regulator_summary.txt` | `/sys/kernel/debug/regulator/regulator_summary` |
| `gpio.txt` | `/sys/kernel/debug/gpio` |
| `pinconf-<controller>.txt`, `pinmux-<controller>.txt` | `/sys/kernel/debug/pinctrl/<controller>/pinconf-pins` and `pinmux-pins`, same seven controllers as 2026-09-18 |
| `clk_summary.txt` | `/sys/kernel/debug/clk/clk_summary` |
| `regmap/soc:spf_core_platform:lpass-cdc.txt` | `/sys/kernel/debug/regmap/soc:spf_core_platform:lpass-cdc/registers` |
| `tinymix.txt` | `tinymix -D 0` |
| `interrupts.txt` | `/proc/interrupts` |
| `ps.txt` | audio, camera and media processes |
| `when.txt`, `err.txt` | device timestamp, stderr of the reads. Each `err.txt` holds four `Failed to mixer_ctl_get_array` lines from `tinymix` and nothing else. |

Per-state files under `cam/`:

| File | Source |
|---|---|
| `sys-class-camera.txt` | every attribute under `/sys/class/camera/*/*`, one line each. Two attributes return raw bytes (`rear2_sensorid_exif` line 31, `rear_sensorid_exif` line 54), so `grep` treats the file as binary. Use `grep -a`. |
| `leds.txt` | `/sys/class/leds/*` brightness, max_brightness, active trigger |
| `regulator_summary.txt`, `gpio.txt` | as in `hal/` |
| `dumpsys-media.camera.txt` | `dumpsys media.camera` |
| `vendor-camera-files.txt` | `ls -la /vendor/lib64/camera /vendor/lib/camera /vendor/etc/camera` |
| `data-vendor-camera.txt` | `ls -laR /data/vendor/camera` |
| `getprop-camera.txt` | `getprop` filtered for camera, flash, sensor |
| `dmesg-camera.txt` | `dmesg` filtered for camera, CCI, EEPROM, actuator, flash, LED, CSIPHY, sensor |
| `i2c-devices.txt` | every `/sys/bus/i2c/devices/*` with its `name` |
| `remoteproc.txt` | `/sys/class/remoteproc/*` name and state |
| `ps.txt` | audio, camera, media and sensor processes |
| `torch.txt` | only in `06-torch`: the sysfs writes the torch mode made |
| `when.txt`, `err.txt` | device timestamp, stderr. Each `err.txt` holds two lines: `rear_actuator_power: I/O error` and `/vendor/etc/camera: No such file or directory`. |

Top-level files, taken once:

| File | Content |
|---|---|
| `dmesg.txt` | full `dmesg` at the end of the session, 3104 lines, kernel time 150 s to 392 s. The ring buffer had already dropped boot. |
| `clip-07-slpi-off.txt` | `ffprobe` and `ffmpeg volumedetect` summary of the video clip recorded in state 07. The clip itself (55 MB) is not kept. |
| `tlmmsample-recording.txt` | output of `tlmmsample.sh 8` during state 07, and a 3 s idle baseline |

Redaction: the camera module IDs in `cam/*/sys-class-camera.txt` were replaced with `MODULEID-REDACTED`. Six strings were replaced in each of the three files: `front_moduleid` (line 12) and the `CAMIF_ID` in `front_hwparam` (line 10), `rear2_moduleid` (line 28) and the `CAMIR2_ID` in `rear2_hwparam` (line 27), `rear_moduleid` (line 47) and the `CAMIR_ID` in `rear_hwparam` (line 46). No other file contained them. No file contained the device serial (`R52T...`). No file exceeded 1 MB, so nothing was dropped.

## Findings

Each finding cites the file and line that supports it. Line numbers are for the files in this directory.

### 1. The microphones record with the SLPI offline

- `cam/07-slpi-off-recording/remoteproc.txt` line 4: `remoteproc3 2400000.remoteproc-slpi offline`. Every other remoteproc is `running` (lines 1 to 3 and 5).
- `dmesg.txt` records the stop: line 1248 `remoteproc-slpi: failed receiving QMI response` (241.8 s), line 1255 `fastrpc_pdr_cb: msm/slpi/sensor_pd ... is down`, line 1461 `timed out on wait`, lines 1462 and 1463 `disable_regulators_sensor_vdd Regulator disable: slpi 1800000 uV` and `3000000 uV`, line 1465 `remoteproc remoteproc3: stopped remote processor 2400000.remoteproc-slpi` (254.6 s). The stop took about 13 s.
- `hal/00-idle/interrupts.txt` line 295: IRQ 442 `glink-native-slpi`, count 5897. `hal/07-slpi-off-recording/interrupts.txt` has no IRQ 442; its line 296 is IRQ 443 `glink-native-adsp`.
- `clip-07-slpi-off.txt` line 2: `aac`, 48000 Hz, 2 channels, 25.7 s. Line 3: peak 0.07 dB. Line 4: RMS -21.8 dB. The clip has real audio, not the digital zeros mainline records.
- `hal/07-slpi-off-recording/tinymix.txt` lines 5 and 6: `TX_AIF1_CAP Mixer DEC0` and `DEC1` On. Lines 29 and 30: `TX DMIC MUX0` = `DMIC3`, `TX DMIC MUX1` = `DMIC1`. Lines 53 and 54: `TX_DEC0 Volume` and `TX_DEC1 Volume` 90. Line 343: `CODEC_DMA-LPAIF_RXTX-TX-3 Channel Map` `02 00 00 00 03 ...`. The idle values in `hal/00-idle/tinymix.txt` at the same lines are Off, Off, ZERO, ZERO, 102, 102 and all zero. This is the same route the 2026-09-18 recording used.

The sensor hub is not needed for the microphones to work. Whatever mainline is missing, it is not something the SLPI does.

Host-side, from the vendor image (not in this directory): `/vendor/etc/audio/sku_taro/mixer_paths.xml` defines `main-mic` as `TX DMIC MUX0` = `DMIC1`, `sub-mic` as `TX DMIC MUX1` = `DMIC3`, and `sub-main-mic` as MUX0 = `DMIC3` plus MUX1 = `DMIC1`; `camcorder-multi-mic` uses `sub-main-mic`. The mux values at lines 29 and 30 are the `sub-main-mic` path. `/vendor/etc/microphone_characteristics.xml` declares four builtin microphones: bottom, back and two without a location name.

### 2. On stock all four DMIC pads toggle during recording

- `tlmmsample-recording.txt` lines 3 to 6, 8 s during state 07, 169 rounds: `tlmm171` 76 transitions, `tlmm172` 84, `tlmm173` 77, `tlmm174` 80, each split roughly half low and half high. Lines 8 to 11, 3 s idle baseline: all four `low=15 high=0 transitions=0`.
- The snapshots agree. `hal/00-idle/gpio.txt` lines 234 to 237: TLMM `gpio171` to `gpio174` all `in low func0 2mA pull down`. `hal/07-slpi-off-recording/gpio.txt` lines 235 and 236: `gpio172` and `gpio173` read `high` at the instant of the read; lines 234 and 237: `gpio171` and `gpio174` read `low`.
- The four pads are unclaimed in TLMM: `hal/00-idle/pinmux-f000000.pinctrl.txt` lines 174 to 177, `(MUX UNCLAIMED) (GPIO UNCLAIMED)`, unchanged in state 07.
- The sampler reads `/sys/kernel/debug/gpio` in a shell loop at about 21 rounds per second (169 rounds in 8 s, `tlmmsample-recording.txt` line 2). A DMIC clock in the MHz range aliases at that rate. The counts show that a pad moves, not its frequency.

The mainline comparison is in issue #7, comments of 2026-09-21, not in this directory: on mainline only `gpio171` toggles and `gpio172` is flat.

### 3. The LPI DMIC pins are unclaimed at idle and driven during recording

`diff hal/00-idle/gpio.txt hal/07-slpi-off-recording/gpio.txt`, LPI chip (`gpiochip6`, `lpi_pinctrl@3440000`, header at line 1):

- Lines 8 to 11 idle: `gpio6` to `gpio9` all `in 0 2mA pull down`.
- Lines 8 to 11 recording: `gpio6 out 1 2mA no pull`, `gpio7 in 1 2mA no pull`, `gpio8 out 1 2mA no pull`, `gpio9 in 1 2mA no pull`. The two clock lines become outputs, the two data lines inputs, all pulls off.
- `hal/00-idle/pinmux-soc:spf_core_platform:lpi_pinctrl@3440000.txt` lines 9 to 12: pins 6 to 9 `(MUX UNCLAIMED) (GPIO UNCLAIMED)`. `hal/07-slpi-off-recording/pinmux-soc:spf_core_platform:lpi_pinctrl@3440000.txt` lines 9 to 12: `gpio6`, `gpio7` claimed by `cdc_dmic01_pinctrl`, `gpio8`, `gpio9` by `cdc_dmic23_pinctrl`, all `func1`. The `pinconf-` file for the LPI controller does not differ between the two states.

This differs from 2026-09-18, where the same pins were already claimed at idle (`../2026-09-18/README.md`, finding 2). The vendor releases the pin groups when no capture is open and claims them on demand. Nothing here says why the 2026-09-18 idle snapshot caught them claimed.

### 4. No regulator changes for recording; L2C and L13C belong to the SLPI

`diff hal/00-idle/regulator_summary.txt hal/07-slpi-off-recording/regulator_summary.txt`, 94 changed lines:

- Lines 220 and 221: `pm8350c_l2` use_count 1 to 0, 1800 mV. Its only consumer is `2400000.remoteproc-slpi-sensor_vdd`, use 1 to 0.
- Lines 238 and 239: `pm8350c_l13` use_count 1 to 0, 3000 mV. Its only consumer is `2400000.remoteproc-slpi-sensor_vddio`, use 1 to 0.
- Both rails still read their voltage with use_count 0 and open_count 1. `dmesg.txt` lines 1462 and 1463 are the driver disabling them. They are the SLPI's sensor rails, not microphone rails. This closes the L2C item in the runbook's "When to use" list: forcing L2C on could not have helped.
- No other `pm8350c_lN` or `pm8350_lN` LDO changed. The remaining changed lines (3, 5, 52, 62 to 63, 69 to 83, 90 to 93, 99 to 205) are camera, video, display and UFS consumers: `cam_cc_*` and `video_cc_*` GDSCs, `csiphy1`, `cci0`, `cam-cpas`, `ife2`, `ipe0`, the `mmcx`, `mxa`, `mxc` and `vdd_mm` level votes, `mdss_dsi_phy0`, `ufshc` and `ufsphy_mem`. Same class of change as 2026-09-18 finding 2.

### 5. GPIO, pinmux and clock changes idle to recording

`diff hal/00-idle/gpio.txt hal/07-slpi-off-recording/gpio.txt`, TLMM chip (`gpiochip0`, header at line 66):

- `gpio188` to `gpio191` (lines 251 to 254), `gpio196` to `gpio199` (lines 259 to 262) and `gpio202` (line 265) go `high` to `low`. All are `in func0 2mA pull down` and unclaimed. None of them moved in the 2026-09-18 idle-to-recording diff (`../2026-09-18/README.md`, finding 2), so they are the SLPI stop, not the camera. `gpio189` is not steady while the SLPI runs: `hal/00-idle/gpio.txt` line 252 reads `high`, `cam/00-idle/gpio.txt` line 252 two seconds later reads `low`, `cam/06-torch/gpio.txt` line 252 reads `high` again.
- Camera on: `gpio103` pull down to no pull (line 166), `gpio107` out low to high (line 170), `gpio110` to `gpio113` low to high (lines 173 to 176), `gpio117` out low to high (line 180), `gpio120` out low to high (line 183). `hal/07-slpi-off-recording/pinmux-f000000.pinctrl.txt`: `gpio103` claimed by `cam-sensor0` as `cam_mclk` (line 106), `gpio120` by `cam-sensor0` (line 123), `gpio117` by `cam-res-mgr` (line 120), the `cci_i2c` claim moves from `gpio110`, `gpio111` to `gpio112`, `gpio113` (lines 113 to 116).
- Also changed: `gpio8`, `gpio9` low to high (lines 75 and 76), `gpio208`, `gpio209` low to high (lines 271 and 272), and `gpio172`, `gpio173` (finding 2). The first two pairs are I2C lines idling high once their bus is active, same as 2026-09-18.
- PMIC GPIO chips (lines 26 to 65): no difference.

`diff hal/00-idle/clk_summary.txt hal/07-slpi-off-recording/clk_summary.txt`, 196 changed lines. The only audio clock is `audio_lpass_mclk6`, enable count 0 to 1 (`hal/07-slpi-off-recording/clk_summary.txt` line 19). `cam_cc_mclk3_clk_src` and `cam_cc_mclk3_clk` turn on for the sensor. The rest are camera, video, display and GPU clocks.

`diff hal/00-idle/regmap/soc:spf_core_platform:lpass-cdc.txt hal/07-slpi-off-recording/regmap/soc:spf_core_platform:lpass-cdc.txt` changes 16 registers (32 diff lines): `0x0000`, `0x0004` 00 to 01 (lines 1 and 2); `0x0100` 00 to 40 (line 18); `0x0108` 00 to 20 (line 20); `0x0400` 04 to 24, `0x0404` 10 to 90 (lines 50 and 51); `0x040c` 12 to 06 (line 53); `0x0480` 04 to 24, `0x0484` 10 to 90 (lines 62 and 63); `0x048c` 12 to 06 (line 65); `0x3000`, `0x3004` 00 to 01 (lines 759 and 760); `0x3080` 00 to 02, `0x3084` 00 to 05, `0x3088` 00 to 05 (lines 762 to 764); `0x3094` 80 to 00 (line 767). Thirteen of these are the 2026-09-18 set (finding 3 there). `0x0404`, `0x0484` and `0x3094` are new this session.

### 6. Torch: two LEDs at 75 of 500, one switch

- `cam/00-idle/leds.txt` lines 3 and 4: `led:flash_0`, `led:flash_1` max 1500. Lines 10 and 11: `led:torch_0`, `led:torch_1` max 500. Line 9: `led:switch_2`, trigger `switch2_trigger`. Lines 5, 6, 12, 13: `flash_2`, `flash_3`, `torch_2`, `torch_3` exist with no trigger.
- `cam/06-torch/leds.txt` lines 10 and 11: `torch_0` and `torch_1` brightness 75. Line 9: `switch_2` brightness 1. `diff cam/00-idle/leds.txt cam/06-torch/leds.txt` touches lines 9 to 11 and nothing else.
- `dmesg.txt` lines 851 to 854: `flash_power_store: torch value_u32=1`, `Led_Torch[0]: Current: 75 max_current 500`, `Led_Torch[1]: Current: 75 max_current 500`, `torch on`. Lines 931 and 932: `torch value_u32=0`, `torch off`. Both LEDs light together from one sysfs write.
- `diff cam/00-idle/regulator_summary.txt cam/06-torch/regulator_summary.txt` changes only UFS state: `pm8350c_s6_level` (line 52), `gcc_ufs_phy_gdsc` (lines 62 and 63), the `ufsphy_mem` consumers of `pm8350_l5` and `pm8350_l6` (lines 177, 189, 193, 205). `diff cam/00-idle/gpio.txt cam/06-torch/gpio.txt` changes only `gpio189` (line 252, see finding 5). Nothing torch-related moved. The torch does not show up as an AP-visible regulator or GPIO.

### 7. Camera inventory

`cam/00-idle/sys-class-camera.txt`:

- Rear: line 40 `rear_camtype: HYNIX_HI1337`, line 36 `rear_camfw: H13EFOFW0HM`, line 34 `rear_afcal: 20 582 422` (AF calibration present), line 35 `rear_calcheck: Normal Normal`, line 51 `rear_paf_cal_check: 120400C9`.
- Rear ultrawide: line 22 `rear2_camtype: HYNIX_HI847`, line 19 `rear2_camfw: R08EFOGW0HM`, line 26 `rear2_dualcal_size: 2060`.
- Front: line 7 `front_camtype: HYNIX_HI1337`, line 4 `front_camfw: I12EFOIF1MM`, line 3 `front_afcal: 20`.
- Line 56 `supported_cameraIds: 56 58 3`. `cam/07-slpi-off-recording/dumpsys-media.camera.txt` line 12: camera ID 56 held by `com.sec.android.app.camera` pid 18187; line 41 `Device 56 is open`; line 98 `VIDEO_RECORD`; line 932 `Device status: ACTIVE`.

`dmesg.txt` line 1646: `cam_sensor_match_id: hi1337 read id: 0x2000 expected id 0x2000`. Line 1647: `CAM_ACQUIRE_DEV Success for hi1337 sensor_id:0x2000, sensor_slave_addr:0x42`, at 282 s, inside the recording window (`cam/07-slpi-off-recording/dmesg-camera.txt` ends at 315 s). An HI1337 answers at I2C slave `0x42` with ID `0x2000`. `hi847` does not appear in `dmesg.txt` or any `dmesg-camera.txt`; the ultrawide was not opened during the buffer's 150 s to 392 s window.

`cam/00-idle/data-vendor-camera.txt` lines 10 to 12: `eeprom_hi1337_otp.bin` 2016 bytes, `eeprom_hi847_uw_otp.bin` 2080 bytes, `eeprom_p24c256f_hi1337.bin` 11024 bytes. `cam/00-idle/getprop-camera.txt` lines 27 to 29 carry the same three sizes as `service.camera.hi1337_otp`, `hi847_uw_otp` and `p24c256f_hi1337`. By the file names, one HI1337 has its calibration in a P24C256F EEPROM and the other two sensors carry theirs in sensor OTP.

`cam/00-idle/i2c-devices.txt` lines 9 and 10: `60-0018 actuator`, `60-0058 eeprom`. Line 1: `18-0020 tcm-i2c`, where 2026-09-18 listed an unnamed `18-0020`. Lines 2 to 5: the four `cs35l45`.

`cam/00-idle/vendor-camera-files.txt`, `/vendor/lib64/camera` (header at line 45): sensor module blobs at lines 69 to 75, `com.samsung.sensormodule.0_hynix_hi1337.bin`, `1_hynix_hi1337_front.bin`, `2_hynix_hi847_uw.bin`, `2_lsi_gc5035.bin`, plus `12_hynix_hi1337_front_full`, `12_hynix_hi847_full` and `1_hynix_hi847`. The `gc5035` blob is an alternate second-slot sensor that this unit does not report. Sensor drivers `com.samsung.sensor.gc5035.so`, `hi1337.so`, `hi847.so` at lines 55 to 57. The same set under `/vendor/lib/camera` (header at line 1) at lines 11 to 13 and 25 to 31. `/vendor/etc/camera` does not exist (`cam/00-idle/err.txt` line 2).

## Procedure lessons

The runbook carries these. The short form:

- Stock does not format the pmOS userdata. It stops in recovery with a corrupt-data prompt. The factory reset it offers is the userdata wipe.
- KernelSU manager v1.0.5 installs with `adb install`. Root for `adb shell su` is granted to Shell (`com.android.shell`) from the Superuser tab.
- Stock has no `/dev/mem` (`CONFIG_DEVMEM` unset), so the TLMM pad sampler cannot map the GPIO registers. `tlmmsample.sh` reads `/sys/kernel/debug/gpio` in a loop, about 21 rounds per second. Enough to tell toggling from flat, not enough for frequency.
- `echo stop` to the SLPI remoteproc takes about 13 s and logs a QMI timeout and a wait timeout before `stopped remote processor` (`dmesg.txt` lines 1248, 1461, 1465). The sensors HAL stays up (`cam/07-slpi-off-recording/ps.txt` line 3 `sscrpcd`, line 5 `sensors@2.1-service.multihal`).
- `camsnap.sh` is a companion to `fastsnap.sh` for the same round trip. Its torch mode writes `1` and `0` to `/sys/class/camera/flash/rear_flash` around the reads. `rear_torch_flash` did not exist on this kernel (`torch.txt` has only `rear_flash` lines).
- `sys-class-camera.txt` holds raw bytes from two `sensorid_exif` attributes. Plain `grep` reports the file as binary and prints no matching line. Redaction passes and searches on it need `grep -a`.
- The recorded clip is 55 MB and is not kept. `ffprobe` and `ffmpeg -af volumedetect` output is the artifact (`clip-07-slpi-off.txt`).

## Still not confirmed

- Which physical microphone is `DMIC1` and which is `DMIC3`, and how the four builtin microphones in the host-side `microphone_characteristics.xml` map onto LPI `gpio6` to `gpio9` and `gpio12`, `gpio13`. The files here show two DMIC pairs clocked and two decimators used. The location names are not in this directory.
- Why mainline toggles only `gpio171`. That is the issue #7 comparison, not a file here.
- Which sensor camera ID 56 is. The rear and the front sensor are both HI1337 (`sys-class-camera.txt` lines 40 and 7), so the `hi1337` lines in `dmesg.txt` do not by themselves say which one the recording used. The operator recorded with the app's default, the rear camera.
- The SLPI `offline` reads before and after state 07 are session observations. The one filed read is `cam/07-slpi-off-recording/remoteproc.txt` line 4, taken during recording.
- The torch turning off is filed only as `dmesg.txt` lines 931 and 932 and `torch.txt` line 2. No `leds.txt` was taken after the `0` write.
- The LPI DMIC pins were unclaimed at idle here and claimed at idle on 2026-09-18. Nothing in either set explains the difference.
- The three codec registers new to this session's diff (`0x0404`, `0x0484`, `0x3094`) are not identified.
- No idle-after snapshot. Whether stopping the SLPI leaves state behind after the camera app closes is not shown.
- `hi847` and the second `hi1337` were never opened while `dmesg` was captured. Their slave addresses and sensor IDs are not in these files.
- No vendor XML (`mixer_paths.xml`, `microphone_characteristics.xml`) is included. Samsung's files stay out of the repo. The claims about them above are host-side readings of the vendor image.
- The device clock in `when.txt` is wrong. Order the states by directory name, not by timestamp.
