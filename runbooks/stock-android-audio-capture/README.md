# Runbook: stock Android audio evidence capture

Device: SM-X800 (gts8pwifi), SM8450. Host: Arch, `odin4`, `adb`, artifacts in `root-build/`.

One flash round trip: pmOS off, rooted stock Android on, run the snapshot scripts (`fastsnap.sh`, `camsnap.sh`, `tlmmsample.sh`, or the scripted `capture.sh`), pmOS back.
The session answers two questions the mainline port cannot answer from its own side.

1. What powers or gates the microphones. Which regulator, GPIO or clock changes when stock records.
2. How the vendor configures the four CS35L45 amplifiers. Register state during playback, mixer paths, firmware names and hashes.

## When to use

Use this when the mainline side is exhausted. That is the state in `docs/10-audio.md`, section "Microphones", and GitHub issue #7.

- Capture streams on `VA_CODEC_DMA_TX_0` and every recording is digital zeros.
- Every readable SoC register matches Samsung's downstream sequence.
- L2C, L4C, L5C forced on changed nothing. S10B is on. The PMIC arbiter refuses AP reads of the other RPMh-owned LDOs.
- Stock's VA macro node, init scripts and mixer paths name no mic supply.
- The 7.2 retest is spent (issue #7, comment of 2026-09-18).

The speaker side has a separate open item. Volume is capped at 420 of 457 because no speaker-protection firmware is loaded. The vendor's CS35L45 register state and firmware inventory feed that work.

Do not run this for a question that a mainline boot can answer. The round trip destroys the pmOS rootfs.

## Prerequisites

Host:

- `adb`, `odin4`, `diff`, `python3` (only for the `--playback tinyplay` tone; the script degrades without it).
- Repo checked out with `root-build/` present. Needed files, all present as of 2026-09-18:

| File | Role |
|---|---|
| `root-build/kernelsu_boot.tar` | stock boot.img with the KernelSU kernel (docs/01) |
| `root-build/android_restore.tar` | stock `boot.img` + `vendor_boot.img` |
| `root-build/vbmeta_disabled.tar` | verity off, needed for a modified boot |
| `root-build/stock_boot.tar` | pristine stock boot, restore insurance |
| `root-build/pmos_uniloader_boot.tar` | current pmOS boot image |
| `root-build/combined.img` | pmOS rootfs GPT image (built 2026-07-20) |
| `root-build/pmos_userdata_sparse.tar` | sparse form of the above, what `make flash-all` writes |

- KernelSU manager APK. `docs/01` step 7 names tiann KernelSU v1.0.5. Fetch it with `gh release download v1.0.5 -R tiann/KernelSU -p 'KernelSU_*.apk'`. It installs with `adb install` (step 4). The pmOS user home may also hold a copy (see the backup list).

Device:

- Bootloader already unlocked and Knox already tripped (docs/01). No re-unlock is needed.
- Battery charged. The stock first boot and the setup wizard take time.
- USB cable on a direct host port, not a deep hub (docs/05 §5).

Knowledge:

- Download mode choreography from `docs/05` §5 and the README "Flashing gotchas". Every `odin4` call needs a freshly entered download mode.
- `make flash-help` for the flash flavors.

## Irreversible points

- **Stock Android cannot use the pmOS userdata.** userdata holds the combined pmOS GPT image (`docs/05` §8b). Stock expects an f2fs `/data`. Stock does not format it on its own: it stops in recovery with a corrupt-data prompt, and the factory reset it offers is the userdata wipe (confirmed 2026-09-21). Either way the pmOS rootfs is gone.
- **Do not let stock Android OTA.** The unit runs One UI 7, `X800XXU9DYDC` (device-facts). A newer bootloader raises anti-rollback and can lock out the current boot images. Skip Wi-Fi in the setup wizard, or decline every update prompt.
- **Never flash `xbl`, `abl`, `aop`, `tz`, `pmic`.** Only `boot`, `vendor_boot`, `vbmeta`, `userdata` are written here. Download mode is the only recovery floor.

## Step 1: back up pmOS

Do this over ssh while pmOS is still running. Everything on userdata is lost in step 3.

Copy off the tablet:

```sh
IP=<tablet ip>; B=~/gts8p-pmos-backup-$(date +%F); mkdir -p "$B"
scp "user@$IP:/home/user/*.img" "$B/"          # partition dumps kept on the device
scp "user@$IP:/home/user/*.apk" "$B/"          # KernelSU manager or other APKs parked there
scp "user@$IP:/home/user/.ssh/authorized_keys" "$B/authorized_keys"
ssh "user@$IP" 'nmcli -t -f NAME,UUID connection show' > "$B/nm-connections.txt"
ssh "user@$IP" 'ls -la /home/user' > "$B/home-listing.txt"
```

Also lost and rebuilt after restore, per `tools/README.md`:

- The `gts8pwifi-setup` toolkit packages.
- The staged GPU zap and ADSP firmware (`gts8pwifi-fw-extract`).
- The NetworkManager Wi-Fi profile.
- Anything installed since `root-build/combined.img` was built on 2026-07-20.

If `/home/user` holds anything else you care about, copy it now. The listing file is your reminder.

## Step 2: enter download mode

From pmOS the reboot-reason path may not work (`tools/reboot-download.py` header). The method that worked on 2026-09-18:

1. Unplug USB.
2. Shut the device down gracefully (`sudo poweroff` on pmOS, or the power menu on stock). Wait for the screen to go black.
3. Hold both volume keys and plug USB. The device powers straight into the download screen. No Warning screen, no Vol-Up.
4. `make device-status`. The USB device number must be new for this entry.

Fallback, if the device is hung and will not shut down:

1. Hold Vol-Down + Power until the screen goes black.
2. Hold both volume keys, plug USB. Blue Warning screen appears.
3. Vol-Up to continue.
4. `make device-status` as above.

A failed `odin4` transfer wedges the download session. The next `odin4` call fails with `FAIL! (Auth)` or hangs until download mode is entered again. Unplug, shut down, re-enter.

## Step 3: flash rooted stock

One `odin4` session writes boot, vendor_boot and vbmeta. Build a single AP tar that holds all three images. Splitting vbmeta into `-u` was not needed on 2026-09-18. One tar, one `-a`, one session.

```sh
cd root-build
mkdir -p stock-rooted && cd stock-rooted
tar -xf ../kernelsu_boot.tar boot.img
tar -xf ../android_restore.tar vendor_boot.img
tar -xf ../vbmeta_disabled.tar vbmeta.img
tar -H ustar -cf ../kernelsu_restore.tar boot.img vendor_boot.img vbmeta.img
cd ..
odin4 -l
odin4 -a kernelsu_restore.tar
```

The tar pairs the KernelSU boot with the stock vendor_boot and the verity-off vbmeta, which is what `make restore-android` and `docs/01` step 5 do between them.

Then Vol-Down + Power to leave download mode. Stock boots.

Stock stops in recovery with a corrupt-data prompt. Take the factory reset. That is the userdata wipe from "Irreversible points". Stock then boots into the setup wizard.

Unrooted alternative: `make restore-android`, then a second download-mode entry and `odin4 -a root-build/kernelsu_boot.tar`. Two sessions, same result.

## Step 4: root shell over adb

1. Setup wizard: skip Wi-Fi and accounts. Decline updates.
2. Settings, About tablet, Software information, tap Build number seven times. Developer options, enable USB debugging.
3. Plug in, accept the RSA prompt on the tablet. `adb devices` shows `device`.
4. `gh release download v1.0.5 -R tiann/KernelSU -p 'KernelSU_*.apk'`, then `adb install KernelSU_*.apk`. Open the manager once. In its Superuser tab, find Shell (`com.android.shell`) and grant root (docs/01 step 7).
5. Check: `adb shell su -c id` prints `uid=0`. `adb root` will not work on a production build. The script tries both.

## Step 5: run the capture

Two paths. The manual fast-state path is what produced `device-facts/stock-runtime/2026-09-18/` and `2026-09-21/`. The `capture.sh` path is the scripted version and has two constraints learned on the first run, listed below.

### 5a. Manual fast-state procedure (used 2026-09-18 and 2026-09-21)

Three on-device scripts, all `#!/system/bin/sh`, all run as root through `su -c`:

| Script | What it does | Output |
|---|---|---|
| `fastsnap.sh NAME` | regulator, GPIO, pinctrl, clock, the audio regmaps, `tinymix`, `/proc/interrupts`, audio and media processes. A few seconds. Skips the four CS35L45 regmaps, which are the slow part of `capture.sh`. | `/data/local/tmp/audiocap/hal/NAME/` |
| `camsnap.sh NAME [torch]` | Samsung camera sysfs (`/sys/class/camera`), LED class, `dumpsys media.camera`, vendor camera file lists, `/data/vendor/camera`, camera getprops, camera dmesg lines, I2C devices, remoteproc states, audio, camera, media and sensor processes. With `torch` it writes `1` to `/sys/class/camera/flash/rear_flash` before the reads and `0` after, and logs the writes to `torch.txt`. Everything else is a read. | `/data/local/tmp/audiocap/cam/NAME/` |
| `tlmmsample.sh [SECONDS]` | samples TLMM `gpio171` to `gpio174` (the TLMM view of LPI `gpio6` to `gpio9`, the DMIC pads) from `/sys/kernel/debug/gpio` for SECONDS (default 5) and prints per pad the low and high counts, the transitions and the rounds. | stdout, save it by hand |

`fastsnap.sh` and `camsnap.sh` take a state name and are run once per state. `tlmmsample.sh` is run while a state holds.

```sh
cd runbooks/stock-android-audio-capture
adb push fastsnap.sh camsnap.sh tlmmsample.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/fastsnap.sh 00-idle'
adb shell su -c 'sh /data/local/tmp/camsnap.sh 00-idle'
# put the tablet in the next state, then:
adb shell su -c 'sh /data/local/tmp/fastsnap.sh 01-video-recording'
# ... one call per state ...
adb shell su -c 'sh /data/local/tmp/camsnap.sh 06-torch torch'
adb shell su -c 'sh /data/local/tmp/tlmmsample.sh 8' | tee out/tlmmsample-recording.txt   # while recording
adb pull /data/local/tmp/audiocap/hal ./out/hal
adb pull /data/local/tmp/audiocap/cam ./out/cam
```

States used on 2026-09-18, in order:

| Name | State | How |
|---|---|---|
| `00-idle` | home screen | nothing running |
| `01-video-recording` | camera app recording video | `com.sec.android.app.camera`, video mode, tap Record |
| `02-front-camera` | front camera preview | camera app, switch sensor |
| `03-back-camera` | back camera preview | camera app, switch sensor |
| `04-idle-after` | camera app closed | none |
| `05-playback` | Gallery playing the recorded clip | open the clip from step 01 |

States added on 2026-09-21 (`device-facts/stock-runtime/2026-09-21/`). The numbering continues so the two sessions do not collide:

| Name | State | How |
|---|---|---|
| `00-idle` | home screen, SLPI running | `fastsnap.sh` and `camsnap.sh` |
| `06-torch` | rear torch on | `camsnap.sh 06-torch torch` |
| `07-slpi-off-recording` | SLPI stopped, camera app recording video | `echo stop > /sys/class/remoteproc/remoteproc3/state` (about 13 s, check `cat .../state` reads `offline`), then camera app, video mode, Record. `fastsnap.sh`, `camsnap.sh` and `tlmmsample.sh 8` while it records. |

Stopping the SLPI is reversible with `echo start` to the same file, or a reboot. It takes the sensors (accelerometer, gyro, magnetometer, light) with it while stopped.

Keep the ffprobe or `ffmpeg -af volumedetect` summary of any clip recorded, not the clip. The 2026-09-21 clip was 55 MB.

For `05-playback` also dump one or more amps by hand while the clip plays. Each dump is about 400 KB and takes over a minute:

```sh
adb shell su -c 'D=/data/local/tmp/audiocap/hal/05-playback; mkdir -p $D/regmap-amps; timeout 120 cat /sys/kernel/debug/regmap/18-0030/registers > $D/regmap-amps/18-0030.txt'
```

No voice recorder app is installed on stock. The camera app in video mode is the HAL-routed microphone path. It is the only one.

### 5b. Scripted path

```sh
cd runbooks/stock-android-audio-capture
./capture.sh --out ./out
```

Default modes are HAL-routed and need two taps on the tablet: start a recording in the app the script opens, then play the system sound it opens. The script prompts and waits at each point. The prompts read `/dev/tty`, so run it from a terminal. An automated adb session without a tty cannot answer them.

Constraints from the first run:

- One `capture.sh` snapshot takes about five minutes. The four CS35L45 regmaps are about 400 KB each and are read over I2C. `--seconds` must exceed one snapshot or the active state ends before `01-recording` is read. Use `--seconds 360` or more. The script enforces 300 as the floor when `--record tinycap` is in effect.
- `tinycap` and `tinyplay` are not viable on this device. `tinycap` on a backend PCM under AudioReach returns zero frames. The raw-mode control pass (`--no-prompt`) answers nothing. Only HAL-routed states are meaningful.
- No voice recorder app is installed on stock, so the recorder intent the script fires has nothing to open. Use `--record manual` and start a camera video recording by hand when prompted.

Flags:

| Flag | Effect |
|---|---|
| `--out DIR` | parent for the timestamped result dir (default `./out`) |
| `--serial S` | `adb -s S` |
| `--seconds N` | recording and playback window, at least 8 (default 20). At least 300 with `--record tinycap`. Must exceed one snapshot, about five minutes, for the recording state to be captured. |
| `--record voicenote\|tinycap\|manual\|skip` | how the recording phase is started |
| `--playback view\|tinyplay\|manual\|skip` | how the playback phase is started |
| `--i2cdetect` | run `i2cdetect -y -r` on every bus. Off by default: probing a live bus can disturb devices. |
| `--no-prompt` | never wait for a tap; switches defaults to tinycap/tinyplay |
| `--keep-device-copy` | leave the capture under `/data/local/tmp/audiocap` on the tablet |

Results land in `out/<stamp>/`:

- `headline.txt`: the changed lines, idle to recording and idle to playback, for regulators, GPIO, pinctrl, clocks, DAPM widgets and each regmap. Also printed to stdout.
- `diff/`: the full unified diffs.
- `device/00-idle`, `01-recording`, `02-playback`, `03-idle-after`: raw snapshots. Each has `regulator_summary.txt`, `regulators/`, `gpio.txt`, `pinctrl/<controller>.<pins|pinmux-pins|pinconf-pins>.txt`, `clk_summary.txt`, `regmap/<dev>.registers.txt`, `dapm-widgets.txt`, `dapm-on.txt`, `tinymix.txt`, `pcm-status.txt`, `interrupts.txt`, `thermal-temps.tsv`.
- `device/static/`: `dmesg.txt`, `getprop.txt`, `cmdline.txt`, `asound-cards.txt`, `asound-pcm.txt`, `i2c/adapters.tsv` (bus number to DT node), `i2c/devices.tsv`, `regmap-index.txt`, `pinctrl-index.txt`, `regulator-index.txt`, `asoc-index.txt`, `thermal-trips.txt`, `vendor/` (every `*.xml` from `/vendor/etc/audio/sku_taro/`, `cs35l45-firmware-sha256.txt`, `sensors-ls.txt`, `firmware-index.txt`).
- `device/notes.txt`: every path the script looked for and did not find. Read this before trusting an empty diff.
- `capture.log`, `host-manifest.txt`.

The regmap filter matches CS35L45 instances (`*-0030` to `*-0033` on whatever bus number stock assigns to `i2c@990000`), the LPASS macros and codec (`*macro*`, `*lpass*`, `*cdc*`, `*swr*`), and the MAX77705 family on `i2c@994000` (`*-0066`, `*-0069`, `*-0036`, `*-0025`, `*charger*`, `*fuelgauge*`, `*muic*`, `*pdic*`). `static/regmap-index.txt` lists everything that existed, so a miss is visible.

## Step 6: file the results

```sh
D=device-facts/stock-runtime/$(date +%F)
mkdir -p "$D"
cp -r runbooks/stock-android-audio-capture/out/hal "$D/"        # fastsnap.sh set
cp -r runbooks/stock-android-audio-capture/out/cam "$D/"        # camsnap.sh set, if any
cp runbooks/stock-android-audio-capture/out/tlmmsample-*.txt "$D/"  # tlmmsample.sh output, if any
cp -r runbooks/stock-android-audio-capture/out/<stamp>/* "$D/"  # capture.sh set, if any
```

Before committing:

- Scrub the camera module IDs from `cam/*/sys-class-camera.txt`: the `*_moduleid` attributes and the `CAMI*_ID` fields in `*_hwparam`. Replace each with `MODULEID-REDACTED`. That file holds raw bytes from the `sensorid_exif` attributes, so `grep` treats it as binary and prints nothing without `-a`: `grep -rn -a -o -E '[HM]VOL[A-Z0-9]{9,11}' "$D"`. On 2026-09-21 there were six per file, three module IDs and their three hwparam copies.
- Scrub the device serial everywhere, also with `grep -a`: `grep -rla <serial> "$D" | xargs sed -i 's/<serial>/SERIAL-REDACTED/g'`. On 2026-09-18 it appeared only in `usb/host-lsusb-v.txt` (`iSerial`). `getprop.txt` and `dmesg.txt` also carry it when `capture.sh` is used. The repo already keeps `device-facts/getprop-full.txt` out of git for that reason.
- Drop files over 1 MB unless one is the point of the capture. A CS35L45 register dump is about 400 KB and stays.
- The vendor `*.xml` copies are Samsung's files. The repo's rule is that Samsung's bytes stay local. Keep the file names and the `sha256` list in git, and keep the copies out.
- Write `$D/README.md`: what was captured, how, the findings with file and line evidence, and what the set does not show. `device-facts/stock-runtime/2026-09-18/README.md` is the template.
- `runbooks/stock-android-audio-capture/out/` is a working directory. Do not commit it.
- Update `docs/10-audio.md` "Microphones" and issue #7 with the finding, whichever way it goes.

## Step 7: restore pmOS

```sh
adb reboot download                  # works on stock
make device-status                   # new USB device number
make uuids                           # DTS bootargs UUIDs must match the rootfs image
make flash-all                       # boot + userdata sparse, one odin session
```

Press Power at "press power button to confirm unverified firmware boot". After pmOS is up:

```sh
ssh user@<ip>
sudo gts8pwifi-setup                 # toolkit packages
sudo gts8pwifi-fw-extract            # GPU zap + ADSP into the initramfs; audio needs this
nmcli dev wifi connect <ssid> password <pw>
```

Then copy `authorized_keys`, the `.img` files and the APKs back from the backup directory.

`make flash-all` writes the July rootfs image. If the device package or kernel moved on since then, `make rootfs`, update the UUIDs in the DTS, `make boot`, then `make flash-all` (README, "Building").

## Expected outcome

The headline names at least one of:

- A regulator on pm8350c or pm8350 whose state flips between `00-idle` and `01-recording` in `regulator_summary.txt`. That is the mic supply. Stock names them `pm8350c_lN` and `pm8350_lN`. Carry the answer into the DTS as a `vdd-micb`-style supply on the VA macro or as an always-on regulator, and retest `arecord`.
- A TLMM or LPI pin whose mux, direction or level changes on recording. Stock DMIC pins are LPI `gpio6/7`, `8/9`, `12/13`, mux `func1`, in `dmic01/23/45_clk_active` and `_data_active`. A TLMM pin changing here is a mic enable line.
- A clock under `clk_summary.txt` that turns on during recording. A `va_*` or `lpass_*` clock that mainline never enables is a candidate.

For the amplifiers:

- `02-playback/regmap/<bus>-0030.registers.txt` against `00-idle` gives the vendor's live CS35L45 configuration. Compare with the mainline driver's register writes.
- `02-playback/dapm-on.txt` lists which amp widgets the HAL enables.
- `static/vendor/mixer_paths.xml` and `cs35l45-firmware-sha256.txt` complete the picture for the speaker-protection follow-up.

`03-idle-after` should match `00-idle`. A difference there is a state that recording or playback left behind, or a snapshot that raced a background job. Note it.

Both passes matter. Changes in the HAL-routed pass and not in the raw pass are the HAL's own doing. Changes in both are the kernel's.

## Rollback

Stock will not boot after step 3:

- Download mode, `odin4 -a root-build/stock_boot.tar -u root-build/vbmeta_disabled.tar`. Stock kernel, no root.
- Still bad: full stock firmware `X800XXU9DYDC` from a mirror, `odin4 -b BL -a AP -s CSC` (docs/01 recovery). Check the bootloader version first; a newer one raises anti-rollback.

pmOS will not boot after step 7:

- `make uuids`. A mismatch is the most common cause (README).
- Initramfs debug shell with `wait_boot_partition`: userdata did not get the combined image. `make flash-all` again, freshly entered download mode.
- `FAIL! (Auth)` from odin: stale session. Re-enter download mode.

What is lost regardless: everything on the pmOS rootfs that step 1 did not copy. What is kept: the stock partitions on the device, the `root-build/` images on the host, download mode.

## Escalation

If the HAL-routed recording pass shows no regulator, GPIO or clock change and `device/notes.txt` shows debugfs was present, the mic supply is not visible to the AP. Candidates are a fixed regulator, a PMIC-internal path, or something the ADSP or the sensor hub drives. Software state cannot go further.

Before the scope, sample the pads in software. TLMM `gpio171` to `gpio174` are the TLMM view of LPI `gpio6` to `gpio9`. Stock has no `/dev/mem` (`CONFIG_DEVMEM` unset), so the GPIO registers cannot be mapped from user space; `tlmmsample.sh` reads `/sys/kernel/debug/gpio` in a loop instead, about 21 rounds per second. That is enough to tell a toggling pad from a flat one, not enough to measure a clock. On 2026-09-21 all four pads toggled during a stock recording and were flat low at idle (`device-facts/stock-runtime/2026-09-21/tlmmsample-recording.txt`). Run the same on mainline for the comparison (issue #7, comments of 2026-09-21).

Next step after that is a scope on LPI `gpio6` (DMIC clock) and `gpio7` (data) during `arecord` on mainline, then the same pins during a stock recording. The device is glued shut. `docs/10-audio.md` calls this the last resort. Open a note on issue #7 with the capture path and the null result before starting it.

If debugfs was not available on the stock kernel (`notes.txt` says so), the sysfs fallbacks in `regulators/sysfs-class-regulator.tsv` still show regulator state, but GPIO, pinctrl, clock and regmap data are absent. Then the session did not answer the question. Options: a userdebug or engineering kernel for `X800XXU9DYDC`, or the scope.

## Facts to confirm on device

Confirmed on 2026-09-18 (`device-facts/stock-runtime/2026-09-18/`):

- debugfs is mountable on the stock 5.10 kernel. `fastsnap.sh` mounts it and every debugfs read in the set succeeded.
- `tinymix` and `tinycap` ship on the stock image. `tinycap` runs but returns zero frames on a backend PCM.
- No voice recorder app is installed. The script's `com.sec.android.app.voicenote` and `RECORD_SOUND` attempts find nothing. The camera app in video mode is the HAL mic path.
- Stock regmap directory names: the amps are `18-0030` to `18-0033` (I2C bus 18). The codec is one regmap, `soc:spf_core_platform:lpass-cdc`. No separate `*macro*` regmap exists.
- KernelSU manager APK: `gh release download v1.0.5 -R tiann/KernelSU -p 'KernelSU_*.apk'`.

Confirmed on 2026-09-21 (`device-facts/stock-runtime/2026-09-21/`):

- Stock does not format the pmOS userdata. It stops in recovery with a corrupt-data prompt. The factory reset it offers is the userdata wipe.
- The KernelSU manager v1.0.5 APK installs with `adb install`. Root for `adb shell su` is granted to Shell (`com.android.shell`) from the manager's Superuser tab.
- Stock has no `/dev/mem`; `CONFIG_DEVMEM` is unset. Pad-level sampling on stock is the debugfs loop in `tlmmsample.sh`, about 21 rounds per second.
- `/sys/class/remoteproc/remoteproc3` is the SLPI. `echo stop` to its `state` works from a root shell and the microphones keep recording with it offline.
- `/sys/class/camera/flash/rear_flash` drives both torch LEDs (`led:torch_0` and `led:torch_1`, 75 of 500) from one write. `rear_torch_flash` does not exist.

Still not confirmed:

- Whether `tinyplay` ships. It was not tried; playback used the Gallery app.
