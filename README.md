# Samsung Galaxy Tab S8+ (SM-X800) — mainline Linux / postmarketOS port

Mainline Linux **boots to a login prompt** on the Galaxy Tab S8+ Wi-Fi
(`gts8pwifi`, Qualcomm SM8450 "Waipio"): kernel 6.13-rc3, all 8 cores, framebuffer
console on the panel, root on UFS, and **remote shell access over USB ethernet**.

No Galaxy Tab S8 port exists upstream — as far as we can tell this is the first.

> **Status: bring-up, remotely usable.** It boots to `samsung-gts8pwifi login:` and
> you can ssh in. Local input is still the weak point — no touchscreen and no
> keyboard yet, so the panel is effectively an output-only console. Not a daily
> driver, but no longer a blind one.

| Component | State |
|---|---|
| Boot (uniLoader → mainline kernel) | ✅ working |
| Display — framebuffer console (simpledrm @ 2800×1752) | ✅ working |
| CPU — all 8 cores | ✅ working |
| UFS storage — root mounted, auto-resized | ✅ working |
| USB host (xhci) | ✅ working |
| USB ethernet + DHCP + **ssh** | ✅ working (Realtek RTL8153 dongle) |
| Power key, volume down (PMIC PON) | ✅ working |
| Volume up (pm8350 gpio-keys) | 🟡 wired, test pending |
| USB gadget | ❌ needs Type-C/`pmic_glink` described |
| Book Cover Keyboard (pogo STM32 @ i2c 0x2a) | 🟡 bus + power up, MCU silent — under investigation |
| Touchscreen (STM FTS1BA90A) | ❌ no mainline driver |
| Native panel driver (S6TUUM1 DDIC) | ❌ not started |
| WiFi / audio / GPU | ❌ not started |

### Getting a shell

There is no working local keyboard yet, so the practical path in is USB ethernet:
plug a **self-powered** USB-C dongle with an ethernet port into the tablet. The
device DHCPs on boot and a bring-up service prints the interface, MAC, address and
gateway straight to the panel whenever they change — read the IP off the screen and
ssh to it.

Holding **volume-down from initial power-on** drops into the postmarketOS initramfs
debug shell, which renders an on-screen keyboard (osk-sdl) on the framebuffer.

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
make deps       # clone uniLoader, apply our board port, install chroot toolchain
make boot       # kernel -> uniLoader -> boot.img -> flashable tar
make flash      # odin4 the boot image (device in download mode)
make help       # everything else
```

Rebuilding the rootfs as well is a longer path, because the rootfs UUIDs are baked
into the DTS bootargs (uniLoader passes no kernel cmdline of its own):

```sh
make rootfs     # pmb install; preserves the image and prints the new UUIDs
                # ...update pmos_boot_uuid / pmos_root_uuid in the DTS to match...
make boot       # rebuild kernel + uniLoader with the new UUIDs
make flash-all  # boot AND userdata in ONE odin session (no reboot between)
make flash-stay # same, but come back up in download mode for the next round
make uuids      # compare the rootfs UUIDs against what the DTS currently says
```

`make uuids` is the cheap sanity check — a mismatch there is the single most common
reason a freshly flashed system drops to the initramfs debug shell.

## Flashing gotchas

These cost us many cycles — see `docs/05` §5:

- **The device must be in a freshly entered download mode.** A session that has sat
  through boot attempts fails with `FAIL! (Auth)`. Worse, the *"an error has occurred
  while updating the device software"* screen enumerates as `04e8:685d` and `odin4 -l`
  finds it, but it will not accept a flash — "fake download mode".
- **userdata must be a sparse image** (`img2simg`). A raw ext4 image fails at ~3%
  with `Fail request receive 3`.
- **userdata must hold the *combined* image**, i.e. `pmb install` *without*
  `--split`. The pmOS initramfs needs both a `pmOS_boot` and a `pmOS_root`
  subpartition, and our real boot partition is occupied by uniLoader — so both have
  to live inside userdata. Flashing only the split `-root.img` leaves no `pmOS_boot`
  and stage-1 stalls forever in `wait_boot_partition`. See `docs/05` §8b.
- **Press Power** at the "press power button to confirm unverified firmware boot"
  prompt or the kernel never runs.
- **Flash multiple partitions in one `odin4` invocation** (`-a` and `-u` together,
  as `make flash-all` does) rather than calling odin twice — that is what caused the
  reboot between writes. `--reboot` is opt-in, and `--redownload` returns the device
  to download mode for the next round.
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
