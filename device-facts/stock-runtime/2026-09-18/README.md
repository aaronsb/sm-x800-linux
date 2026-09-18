# Stock Android runtime capture, 2026-09-18

Rooted stock Android 15 on the SM-X800 (gts8pwifi). Build `X800XXU9DYDC`, kernel `5.10.226-00182-g956d73ce2904` (`stock-build.txt`). Root through KernelSU per `runbooks/stock-android-audio-capture/README.md`. The session answers the questions in GitHub issue #7: what stock does that mainline does not when the microphones record, and how the vendor drives the four CS35L45 amplifiers.

The device clock was not synchronised. Every `when.txt` says `Tue Apr 15 2025`. The host date for the session was 2026-09-18.

## What was captured

Six state snapshots taken with `runbooks/stock-android-audio-capture/fastsnap.sh` (the copy on the device was `/data/local/tmp/fastsnap.sh`). Each snapshot reads debugfs and `tinymix` in a few seconds. The slow `capture.sh` path was not used for the state set. Its four CS35L45 regmap reads take about five minutes per snapshot (see "Procedure lessons").

| Directory | State | How the state was produced |
|---|---|---|
| `00-idle` | home screen, nothing recording or playing | none |
| `01-video-recording` | camera app recording video | `com.sec.android.app.camera` in video mode, Record tapped. This is the only HAL-routed microphone path on stock. No voice recorder app is installed. |
| `02-front-camera` | camera app, front sensor preview | camera app, switch to front |
| `03-back-camera` | camera app, back sensor preview | camera app, switch to back |
| `04-idle-after` | camera app closed | none |
| `05-playback` | Gallery playing the recorded clip through the speakers | Gallery, play the clip from `01-video-recording` |

`01-video-recording/ps.txt` shows `com.sec.android.app.camera` (pid 27504) alongside `audioserver`, `android.hardware.audio.service_64`, `secaudiohalaidl` and `cameraserver`.

Per-state files:

| File | Source |
|---|---|
| `regulator_summary.txt` | `/sys/kernel/debug/regulator/regulator_summary` |
| `gpio.txt` | `/sys/kernel/debug/gpio` |
| `pinconf-<controller>.txt`, `pinmux-<controller>.txt` | `/sys/kernel/debug/pinctrl/<controller>/pinconf-pins` and `pinmux-pins`. Controllers: TLMM `f000000.pinctrl`, LPI `soc:spf_core_platform:lpi_pinctrl@3440000`, PMIC GPIO chips `pm8350@1`, `pm8350c@2`, `pm8450@7`, `pmk8350@0`, `pmr735a@4` |
| `clk_summary.txt` | `/sys/kernel/debug/clk/clk_summary` |
| `regmap/soc:spf_core_platform:lpass-cdc.txt` | `/sys/kernel/debug/regmap/soc:spf_core_platform:lpass-cdc/registers`. The only regmap matching the helper's audio filter. |
| `tinymix.txt` | `tinymix -D 0` |
| `interrupts.txt` | `/proc/interrupts` |
| `ps.txt` | audio, camera and media processes |
| `when.txt`, `err.txt` | device timestamp, stderr of the reads. Every `err.txt` holds three `Failed to mixer_ctl_get_array` lines from `tinymix` and nothing else. |

`05-playback/regmap-amps/18-0030.txt` and `18-0031.txt` are full CS35L45 register dumps (`/sys/kernel/debug/regmap/18-0030/registers`, 22543 lines each) taken during playback. The two files differ, so they are two real devices. Amps `18-0032` and `18-0033` were not dumped.

Top-level files, taken once:

| File | Content |
|---|---|
| `stock-build.txt` | fingerprint, build id, `uname -a` |
| `sensorservice.txt` | `dumpsys sensorservice` |
| `i2c-devices.txt` | every `/sys/bus/i2c/devices/*` with its `name` |
| `getevent-devices.txt` | `getevent -p`, every input device and its capabilities |
| `getevent-buttons.txt` | `getevent -lt` while pressing Volume Down, Volume Up and Power, two presses each |
| `interrupts-after-buttons.txt` | `/proc/interrupts` after the button presses |
| `sysfs-regulators-idle-after.txt` | `/sys/class/regulator/*` name, state and microvolts, the hardware enable state of every regulator |
| `usb/typec-udc-muic-ccic.txt` | `/sys/class/typec/port0`, `/sys/class/udc`, dwc3, muic and ccic sysfs |
| `usb/host-lsusb.txt`, `usb/host-lsusb-v.txt` | `lsusb` on the host for the tablet |

The device serial was replaced with `SERIAL-REDACTED` in `usb/host-lsusb-v.txt` line 17. No other file contained it. No file exceeded 1 MB, so nothing was dropped.

## Findings

Each finding cites the file and line that supports it. Line numbers are for the files in this directory.

### 1. Mic supply candidate: pm8350c_l12 (L12C), 1.8 V, always on

- `00-idle/regulator_summary.txt` line 302: `pm8350c_l12` use_count 1, open_count 1, `fast`, 1800 mV, range 1800 to 1968 mV.
- Line 303 is the only consumer entry under it. It carries the regulator's own name and use 0. No driver holds a reference.
- `sysfs-regulators-idle-after.txt` line 47: `pm8350c_l12 enabled 1800000`. The hardware enable bit is set.
- Stock device tree (`device-facts/dt/stock-fdt.dtb`, local only, decompiled with `dtc`): the `pm8350c_l12` node under `rpmh-regulator-ldoc12` carries `regulator-always-on`. The property appears on exactly two regulators in the whole tree. The other is `dummy_vreg`, a `regulator-fixed`. `display_panel_avdd` carries `regulator-boot-on`, not `regulator-always-on`. That corrects the pre-capture brief.
- The stock tree also names L12C as `vddio-supply` of `qcom,dsi-display-primary` and `qcom,dsi-display-secondary`. L12C is at least the panel I/O rail. Its role as a mic supply is a hypothesis, not a fact shown here.
- Our DTS, `pmaports-overlay/device/testing/linux-postmarketos-qcom-sm8450/sm8450-samsung-gts8pwifi.dts`, declares only `ldo1` (line 494), `ldo7` (line 507) and `ldo8` (line 519) under the `qcom,pm8350c-rpmh-regulators` node (line 467). L12C is not declared.

### 2. No mic-related regulator, GPIO or pin changed between idle and recording

`diff 00-idle/regulator_summary.txt 01-video-recording/regulator_summary.txt`:

- Changed: `regulator-dummy` consumer `mdss_dsi_phy0-gdsc` (line 5), `pm8350c_s6_level` vdd_cx (lines 58 to 76), `gpu_cc_cx_gdsc` (line 74), the mmcx tree under `pm8450_s4_level` (lines 81 to 102), the `video_cc_*` and `cam_cc_*` GDSCs (lines 91 to 164), `pm8350c_s2_level` mxc (line 176), `pm8450_s6_level` mx (line 184), the `csiphy1` consumers of `pm8350_l5` and `pm8350_l6` (lines 230 and 249), and the UFS PHY consumers of the same two LDOs (lines 234 and 253).
- No `pm8350c_lN` or `pm8350_lN` LDO changed its enabled state. `pm8350_l5` and `pm8350_l6` were already on at idle and only gained a consumer.

`diff 00-idle/gpio.txt 01-video-recording/gpio.txt`:

- Input level changes only on TLMM `gpio8`, `gpio9` (owned by `988000.i2c`, `pinmux-f000000.pinctrl.txt` lines 11 and 12), `gpio86` (`mdp_vsync`, line 89), `gpio110` to `gpio113` (`cci0` I2C, lines 113 to 116), `gpio171`, `gpio172` (unclaimed, lines 174 and 175), `gpio208`, `gpio209` (`cci1` I2C, lines 211 and 212).
- Mux changes on `gpio103` (`cam_mclk`, claimed by `cam-sensor0`), `gpio107`, `gpio117` (`cam-res-mgr`) and `gpio120` (`cam-sensor0`): `01-video-recording/pinmux-f000000.pinctrl.txt` lines 106, 110, 120, 123. These are the only pinmux differences.
- PMIC GPIO chips: no difference. `gpio.txt` lines 49 to 60 (pm8350) are identical in both states.
- LPI pinctrl: `pinconf-soc:spf_core_platform:lpi_pinctrl@3440000.txt` and the matching `pinmux-` file are identical in both states. The DMIC pins are already claimed at idle: `gpio6`, `gpio7` by `cdc_dmic01_pinctrl` and `gpio8`, `gpio9` by `cdc_dmic23_pinctrl`, all `func1` (`pinmux-soc:spf_core_platform:lpi_pinctrl@3440000.txt` lines 9 to 12). `gpio12` and `gpio13` are unclaimed (lines 15 and 16).

`diff 00-idle/clk_summary.txt 01-video-recording/clk_summary.txt` has 216 changed lines. The only audio clock among them is `audio_lpass_mclk6`, enable count 0 to 1. The rest are camera, video, display and GPU clocks.

### 3. Stock records through the TX macro, with the VA macro supplying DMIC clocks

`diff 00-idle/tinymix.txt 01-video-recording/tinymix.txt`:

- Lines 5 and 6: `TX_AIF1_CAP Mixer DEC0` and `DEC1` Off to On.
- Lines 29 and 30: `TX DMIC MUX0` ZERO to `DMIC3`, `TX DMIC MUX1` ZERO to `DMIC1`.
- Lines 53 and 54: `TX_DEC0 Volume` and `TX_DEC1 Volume` 102 to 90.
- Line 343: `CODEC_DMA-LPAIF_RXTX-TX-3 Channel Map` all zero to `02 00 00 00 03 ...`. The backend is the RXTX TX-3 codec DMA, not the VA codec DMA that mainline uses.

`diff 00-idle/regmap/soc:spf_core_platform:lpass-cdc.txt 01-video-recording/regmap/soc:spf_core_platform:lpass-cdc.txt` changes 13 registers (26 diff lines):

- `0x0000`, `0x0004`: 00 to 01.
- `0x0100`: 00 to 40. `0x0108`: 00 to 20.
- `0x0400`: 04 to 24. `0x040c`: 12 to 06. `0x0480`: 04 to 24. `0x048c`: 12 to 06.
- `0x3000`, `0x3004`: 00 to 01.
- `0x3080`: 00 to 02. `0x3084`: 00 to 05. `0x3088`: 00 to 05.

The `0x3xxx` block is the VA macro. `0x3080` is VA TOP CFG0. `0x3084` and `0x3088` are the DMIC0 and DMIC1 control registers. The VA block turns on its DMIC clocks while the TX macro (`0x0xxx`) does the decimation. All 13 return to the idle values in `04-idle-after` (zero diff against `00-idle`).

### 4. The amplifiers run Cirrus Protection DSP firmware

- `05-playback/tinymix.txt` lines 207, 235, 263, 291: `RL`, `FL`, `RR`, `FR DSP1 Firmware` = `Protection`. Lines 208 and 212 (and the matching lines for the other three): `DSP1 Preload Switch` On, `DSP1 Boot Switch` On.
- Lines 387 and 388: `RL DSP1 Protection 4fa00 HALO_STATE 00 00 00 09`, `HALO_HEARTBEAT` non-zero. The heartbeat advances between every snapshot (`diff 00-idle/tinymix.txt 01-video-recording/tinymix.txt` lines 388, 487, 586, 685). The DSP is running at idle, not just during playback.
- `diff 04-idle-after/tinymix.txt 05-playback/tinymix.txt`: `AMP Enable Switch` On and `DSP1 Enable Switch` On for all four (lines 353, 354, 362, 363, 371, 372, 380, 381), `AMP PCM Gain 19dB`, `Amplifier Mode SPK`, `Digital PCM Volume 817` for all four (lines 226 to 313). The `Protection cd cspl_*` and `f206 *` controls become readable during playback.
- `05-playback/regmap-amps/18-0030.txt` and `18-0031.txt`: the full register state of two amps under that firmware.

### 5. Volume Up: stock takes edge interrupts on pm8350 gpio6

- `interrupts-after-buttons.txt` line 164: IRQ 282, `spmi-gpio 5 Edge volume_up`, count 38 on CPU0. `00-idle/interrupts.txt` line 164: the same IRQ at count 14. The interrupt fires.
- `getevent-buttons.txt` lines 117 to 123: `KEY_VOLUMEUP` DOWN and UP twice on `/dev/input/event0` (`gpio-keys`). Lines 100 to 110: `KEY_VOLUMEDOWN` on `/dev/input/event3` (`pmic_resin`). Lines 125 to 131: `KEY_POWER` on `/dev/input/event2` (`pmic_pwrkey`).
- `00-idle/gpio.txt` line 55, pm8350 chip: `gpio6 : in high normal vin-1 pull-up 30uA`. That is the same configuration as our `vol_up_default` node (`sm8450-samsung-gts8pwifi.dts` lines 798 to 804: `function = "normal"`, `power-source = <1>`, `bias-pull-up`, `input-enable`). The pin idles high in every snapshot.
- Mainline saw zero edges on this line in July (DTS comment at lines 256 to 263). Pin configuration is not the difference. The PMIC GPIO interrupt path is.
- The claim that the pin reads low while held was observed live in the session. No file in this directory records a snapshot taken with the key held.

### 6. Sensors and AP I2C inventory

`sensorservice.txt`: `lsm6dso LSM6DSO Accelerometer` (line 15) and `Gyroscope` (line 19), `ak0991x AK09918 Magnetometer` (line 17), `VEML3328 Light` ambient (line 21), CCT (line 57) and WideIR (line 51). All report through the SLPI sensor hub. The word `prox` does not appear in the file. There is no proximity sensor.

`i2c-devices.txt`, complete: `18-0030` to `18-0033 cs35l45` (and an unnamed `18-0020`), `55-0028 ISG6320`, `57-0028 ISG6320_SUB` (grip), `59-0063 sm5440-charger`, `60-0018 i2c_actuator`, `60-0058 msm_eeprom` (camera), `61-0066 max77705` with dummies `61-0025`, `61-0036`, `61-0062`, `61-0069`, `62-0018 max77816`, `63-0049 fts_touch`, `64-0028 ps5169` (USB redriver), `65-0023 k250a` (secure element), `66-0056 wacom_w90xx` with dummy `66-0009`, `67-002a stm32_pogo_i2c` with dummy `67-0051`.

### 7. USB on stock

- `usb/typec-udc-muic-ccic.txt` line 2: `data_role=host [device]`. Line 3: `power_role=source [sink]`. Line 4: `port_type=[dual] source sink`. Line 7: `usb_power_delivery_revision=3.0`.
- Lines 37 to 39: UDC `a600000.dwc3`, `configured`, `high-speed`.
- Line 57: `chip_name=max77705`. Line 59: `cur_version=5F.00` (CCIC firmware).
- `usb/host-lsusb.txt` line 1: `04e8:6860`, MTP mode. `usb/host-lsusb-v.txt`: interfaces `MTP` (line 38), `CDC Abstract Control Model (ACM)` (line 87), `ADB Interface` (line 148).

### 8. Procedure lessons

These belong in the runbook and are recorded there. The short form:

- Raw `tinycap` on a backend PCM returned zero frames under AudioReach. Only HAL-routed states are meaningful. The `capture.sh --no-prompt` control pass is not viable.
- `capture.sh` snapshots take about five minutes because the four CS35L45 regmaps are about 400 KB each over I2C. `fastsnap.sh` skips them and takes seconds.
- `capture.sh` prompts read from `/dev/tty`. An automated adb session has no tty. The state set here was taken by hand.
- No voice recorder app is installed on stock. The camera app in video mode is the HAL mic path.
- Download mode entry that worked: graceful shutdown with USB unplugged, then hold both volume keys and plug USB. A failed odin transfer wedges the session until download mode is re-entered.
- One AP tar with `boot.img`, `vendor_boot.img` and `vbmeta.img` flashed in one odin session.

## What this does not show

- Whether L12C powers the microphones. The regulator is on before, during and after recording. Nothing in these files ties it to the DMICs. The stock tree ties it to the display I/O. The test is on the mainline side: declare L12C always-on in our DTS and record.
- The `04-idle-after` state is not identical to `00-idle`. `regulator_summary.txt` differs in 27 lines and `gpio.txt` in 3. These are UFS, GPU and video GDSC use counts settling after the camera app closed, not audio state. `tinymix.txt` and the `lpass-cdc` regmap return to the idle values exactly.
- Only the `lpass-cdc` regmap was captured for the codec. The helper's filter matched no separate VA, TX, RX or WSA macro regmap on this kernel, so the macros are read as one block.
- Amps `18-0032` and `18-0033` have no register dump. Firmware files and their hashes were not collected.
- No snapshot was taken with Volume Up held. The low reading is an observation from the session, not a filed artifact.
- No vendor XML (`mixer_paths.xml`, `audio_platform_info.xml`) is included. Samsung's files stay out of the repo.
- No `dmesg` or `getprop` is included.
- The device clock in `when.txt` is wrong. Order the states by directory name, not by timestamp.
