# Runbook: stock Android audio evidence capture

Device: SM-X800 (gts8pwifi), SM8450. Host: Arch, `odin4`, `adb`, artifacts in `root-build/`.

One flash round trip: pmOS off, rooted stock Android on, run `capture.sh`, pmOS back.
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

- KernelSU manager APK. `docs/01` step 7 names tiann KernelSU v1.0.5. Location on the host: not found in repo, confirm. The pmOS user home may hold a copy (see the backup list).

Device:

- Bootloader already unlocked and Knox already tripped (docs/01). No re-unlock is needed.
- Battery charged. The stock first boot and the setup wizard take time.
- USB cable on a direct host port, not a deep hub (docs/05 §5).

Knowledge:

- Download mode choreography from `docs/05` §5 and the README "Flashing gotchas". Every `odin4` call needs a freshly entered download mode.
- `make flash-help` for the flash flavors.

## Irreversible points

- **Stock Android cannot use the pmOS userdata.** userdata holds the combined pmOS GPT image (`docs/05` §8b). Stock expects an f2fs `/data`. Whether stock formats it on first boot or stops in recovery asking for a factory reset: not found in repo, confirm on device. Either way the pmOS rootfs is gone.
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

From pmOS the reboot-reason path may not work (`tools/reboot-download.py` header). Use the keys.

1. Hold Vol-Down + Power until the screen goes black.
2. Hold both volume keys, plug USB. Blue Warning screen appears.
3. Vol-Up to continue.
4. `make device-status`. The USB device number must be new for this entry.

## Step 3: flash rooted stock

One `odin4` session writes boot, vendor_boot and vbmeta. Build the AP tar once from the existing artifacts. It pairs the KernelSU boot with the stock vendor_boot, which is what `make restore-android` and `docs/01` step 5 do between them.

```sh
cd root-build
mkdir -p stock-rooted && cd stock-rooted
tar -xf ../kernelsu_boot.tar boot.img
tar -xf ../android_restore.tar vendor_boot.img
tar -H ustar -cf ../kernelsu_restore.tar boot.img vendor_boot.img
cd ..
odin4 -l
odin4 -a kernelsu_restore.tar -u vbmeta_disabled.tar
```

Then Vol-Down + Power to leave download mode. Stock boots.

If stock stops in recovery about corrupt data, take the factory reset. That is the userdata wipe from "Irreversible points".

Unrooted alternative: `make restore-android`, then a second download-mode entry and `odin4 -a root-build/kernelsu_boot.tar`. Two sessions, same result.

## Step 4: root shell over adb

1. Setup wizard: skip Wi-Fi and accounts. Decline updates.
2. Settings, About tablet, Software information, tap Build number seven times. Developer options, enable USB debugging.
3. Plug in, accept the RSA prompt on the tablet. `adb devices` shows `device`.
4. `adb install <KernelSU manager apk>`. Open it once. Grant root to Shell (docs/01 step 7).
5. Check: `adb shell su -c id` prints `uid=0`. `adb root` will not work on a production build. The script tries both.

## Step 5: run the capture

```sh
cd runbooks/stock-android-audio-capture
./capture.sh --out ./out
```

Default modes are HAL-routed and need two taps on the tablet: start a recording in the recorder app the script opens, then play the system sound it opens. The script prompts and waits at each point. The prompts matter. `tinycap` and `tinyplay` open raw PCM devices and skip the vendor audio HAL. The HAL is the code that powers the mics and configures the amps, so a raw-PCM run answers a different question.

Run a second pass with the raw modes as a control:

```sh
./capture.sh --out ./out --no-prompt          # tinycap + tinyplay, no taps
```

Flags:

| Flag | Effect |
|---|---|
| `--out DIR` | parent for the timestamped result dir (default `./out`) |
| `--serial S` | `adb -s S` |
| `--seconds N` | recording and playback window, at least 8 (default 20) |
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
cp -r runbooks/stock-android-audio-capture/out/<stamp>/* "$D/"
```

Before committing:

- `getprop.txt` and `dmesg.txt` carry the serial number. The repo already keeps `device-facts/getprop-full.txt` out of git for that reason. Scrub or exclude them.
- The vendor `*.xml` copies are Samsung's files. The repo's rule is that Samsung's bytes stay local. Keep the file names and the `sha256` list in git, and keep the copies out. `.gitignore` has no rule for `device-facts/stock-runtime/` yet. Add one in the same commit.
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

Next step is a scope on LPI `gpio6` (DMIC clock) and `gpio7` (data) during `arecord` on mainline, then the same pins during a stock recording. The device is glued shut. `docs/10-audio.md` calls this the last resort. Open a note on issue #7 with the capture path and the null result before starting it.

If debugfs was not available on the stock kernel (`notes.txt` says so), the sysfs fallbacks in `regulators/sysfs-class-regulator.tsv` still show regulator state, but GPIO, pinctrl, clock and regmap data are absent. Then the session did not answer the question. Options: a userdebug or engineering kernel for `X800XXU9DYDC`, or the scope.

## Facts to confirm on device

Not found in repo, confirm on device:

- Whether stock formats userdata itself or stops in recovery.
- Whether debugfs is mounted or mountable on the stock 5.10 kernel.
- Whether `tinymix`, `tinycap`, `tinyplay` ship on the stock image (`static/manifest.txt` records it).
- The Samsung Voice Recorder component name. The script tries `com.sec.android.app.voicenote/.main.VNMainActivity`, then the generic `RECORD_SOUND` intent, then asks you to open one.
- The stock regmap directory names for the amps and the macros (`static/regmap-index.txt`).
- The host location of the KernelSU manager APK.
