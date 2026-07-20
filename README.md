# Samsung Galaxy Tab S8+ (SM-X800) — mainline Linux / postmarketOS port

Mainline Linux **boots** on the Galaxy Tab S8+ Wi-Fi (`gts8pwifi`, Qualcomm SM8450
"Waipio"): kernel 6.13-rc3, all 8 cores, framebuffer console on the panel, and a
postmarketOS initramfs shell.

No Galaxy Tab S8 port exists upstream — as far as we can tell this is the first.

> **Status: early bring-up.** It boots and you can watch it boot. Storage (UFS) has
> just been wired up; input devices are not working yet. This is not a daily driver.

| Component | State |
|---|---|
| Boot (uniLoader → mainline kernel) | ✅ working |
| Display — framebuffer console (simpledrm @ 2800×1752) | ✅ working |
| CPU — all 8 cores | ✅ working |
| UFS storage | 🟡 wired up, verification pending |
| USB gadget | ❌ `dwc3: failed to initialize core` |
| Touchscreen (STM FTS1BA90A) | ❌ no mainline driver |
| Book Cover Keyboard (pogo) | ❌ no mainline driver; downstream driver identified |
| Native panel driver (S6TUUM1 DDIC) | ❌ not started |
| WiFi / audio / GPU | ❌ not started |

## Why this is unusual

You **cannot** boot mainline Linux directly from Samsung's bootloader on this SoC.
Samsung's ABL merges its own device-tree overlay fragments onto whatever DTB it
selects, which corrupts a mainline device tree — the kernel then dies before any
console exists, giving you a completely silent failure.

The fix is [**uniLoader**](https://github.com/ivoszbg/uniLoader), a secondary
bootloader that embeds the kernel, DTB and ramdisk inside its own binary and
masquerades as a kernel image. Samsung's ABL only ever sees "a kernel" and never
touches our device tree. (`lk2nd` does not support SM8450.)

The full story — including the seven separate silent failures it took to get a
console — is in [`docs/05-mainline-uniloader-boot.md`](docs/05-mainline-uniloader-boot.md).
If you are porting another Samsung SM8450 device, read that first; it will save you
a lot of blind reboots.

## Layout

```
docs/                     Findings, runbooks, and the boot-debug history
  00-recon-findings.md      Device recon
  01-unlock-root-runbook.md Bootloader unlock + root
  02-pmos-port-prep.md      Downstream port prep
  03-boot-debug-log.md      Why the DOWNSTREAM kernel path failed (dead end)
  04-mainline-prep.md       Pivot to mainline; visibility keys from the stock DTB
  05-mainline-uniloader-boot.md   ★ the working recipe + every bug and fix
  06-upstreaming.md         Conventions, versioning, contributing back
pmaports-overlay/         Our postmarketOS packages (the actual port)
  device/testing/linux-postmarketos-qcom-sm8450/   kernel pkg + our DTS + config
  device/testing/device-samsung-gts8pwifi/         device pkg + deviceinfo
  uniloader-port/                                  our uniLoader board port
device-facts/             Non-proprietary device documentation
Makefile                  Build/flash automation
```

Not in git (see `.gitignore`): `pmb-work/`, `kernel-src/`, `reference/`,
`root-build/`, and all Samsung firmware (stock partition dumps, stock DTBs). Those
are Samsung's copyrighted binaries and stay local.

## Building

Requires [pmbootstrap](https://postmarketos.org/pmbootstrap), `odin4`,
`android-tools` (mkbootimg/unpack_bootimg/img2simg), and `dtc`.

```sh
make deps     # clone uniLoader, apply our board port, install chroot toolchain
make boot     # kernel -> uniLoader -> boot.img -> flashable tar
make flash    # odin4 the result (device in download mode)
make help     # everything else
```

## Flashing gotchas

These cost us many cycles — see `docs/05` §5:

- **The device must be in a freshly entered download mode.** A session that has sat
  through boot attempts fails with `FAIL! (Auth)`. Worse, the *"an error has occurred
  while updating the device software"* screen enumerates as `04e8:685d` and `odin4 -l`
  finds it, but it will not accept a flash — "fake download mode".
- **userdata must be a sparse image** (`img2simg`). A raw ext4 image fails at ~3%.
- **Press Power** at the "press power button to confirm unverified firmware boot"
  prompt or the kernel never runs.
- Avoid deep USB hubs; use a direct port.

Only `boot`, `vendor_boot`, `dtbo`, `vbmeta` and `userdata` are ever written.
**Never** flash bootloader or secure-world partitions (`xbl`, `aop`, `tz`, `abl`,
`pmic`, …) — Samsung download mode is the only recovery floor on this device
(EDL/9008 is not viable: it needs a Samsung-signed SM8450 Firehose loader that is
not publicly available).

## Credit

- [uniLoader](https://github.com/ivoszbg/uniLoader) by Ivaylo Ivanov — the piece that
  makes this possible.
- [sm8450-mainline](https://github.com/sm8450-mainline) — kernel tree and SM8450 config.
- `sm8450-samsung-r0q.dts` (Galaxy S22) — the skeleton this port started from.
- [postmarketOS](https://postmarketos.org).

## License

Port sources (DTS, board file, packaging) follow their upstream projects:
GPL-2.0-only for kernel/uniLoader sources, MIT for the pmaports device package.
