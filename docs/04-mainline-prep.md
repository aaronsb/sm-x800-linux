# Phase 3 — Mainline pmOS Port: Launchpad (prep for next session)

**Why mainline:** the downstream Samsung kernel refuses to run any non-Samsung initramfs and
gives ZERO boot visibility (console=null, no display driver, no serial exposed, ramoops needs
Samsung params). See `docs/03-boot-debug-log.md`. **Mainline flips this: `earlycon` + a
`simple-framebuffer` node give us a visible boot** — the actual unlock. We now also have the
real DTB + all vendor blobs to work from.

## The visibility keys (extracted from `device-facts/dt/stock-fdt.dtb`, 2026-07-19)
Pulled from the stock `/chosen` bootargs (the real ones, before Samsung userspace strips them):

- **Serial console (earlycon):** `stdout-path = "/soc/qcom,qup_uart@99c000:115200n8"`,
  `serial0 = qup_uart@99c000` (alias `qupv3_se7_2uart`). SM8450 geni UART.
  → mainline earlycon: `earlycon=qcom_geni,0x0099c000 console=ttyMSM0,115200n8`.
  (Physical access unknown — likely a mainboard test point or USB-C UART via CC-resistor; but
  simplefb below doesn't need it.)
- **Splash framebuffer (simple-framebuffer):** reserved-memory `splash_region` /
  `cont_splash_region` = **`reg = <0x0 0xb8000000 0x0 0x2b00000>`** (base 0xb8000000, 45MB).
  → simplefb node: `reg = <0x0 0xb8000000 0x0 (W*H*4)>; format = "a8r8g8b8";
     width/height/stride` from the panel res (device is 12.4" — try **2800x1752**, stride
     W*4; confirm by reading the live fb or from the panel driver once up).
- **Panel/DDIC:** `msm_drm.dsi_display0=ss_dsi_panel_S6TUUM1_AMSA24VU01_WQXGA`,
  `lcd_id=800005`. This Samsung DDIC is the eventual native-panel driver target (the "big wall").
- Full stock bootargs saved in this doc's git history / re-dump anytime:
  `dtc -I dtb -O dts device-facts/dt/stock-fdt.dtb`.

## SoC / base
- SoC **SM8450 "waipio"**, `compatible = qcom,waipio-mtp / qcom,waipio`.
- Mainline base skeleton: **r0q (Galaxy S22)** — `arch/arm64/boot/dts/qcom/sm8450-samsung-r0q.dts`
  (simple-framebuffer + UFS + USB2 day-1). q4q (Fold4) is the closest Samsung-SM8450 proxy.
- Community fork: **github.com/sm8450-mainline** (linux + `sm8450-mainline/pmaports` fork) —
  has sm8450 device configs + a mainline kernel already carrying sm8450 support. Start here.

## First steps (next session)
1. Clone `github.com/sm8450-mainline/pmaports` (or point pmbootstrap `--aports` at it), and the
   sm8450-mainline linux tree for reference DTS.
2. New device: `device-samsung-gts8pwifi` (mainline category = testing), kernel
   `linux-postmarketos-qcom-sm8450` (shared mainline kernel, NOT a per-device kernel).
3. Write `sm8450-samsung-gts8pwifi.dts` based on `sm8450-samsung-r0q.dts`:
   - `/chosen`: `stdout-path = &uart_console` (the 99c000 geni), bootargs with
     `earlycon console=ttyMSM0,115200n8`.
   - **simple-framebuffer node** at 0xb8000000 (see keys above) + reserve the region — THIS is
     what makes the boot visible on the panel.
   - reserved-memory (copy the sm8450 base memory map; our full map is in stock-fdt.dtb).
   - UFS, USB (day-1). Then a730 GPU (Freedreno + zap), WiFi ath11k (QCA6490 + board-2.bin BDF
     pulled from super.img /vendor/firmware), regulators (pm8450 family).
4. deviceinfo: mainline kernel, `flash_method=heimdall-bootimg`, header v4. Boot via odin4 as
   before (boot + vbmeta, NEVER bootloader partitions — Download mode is the only recovery floor,
   EDL is not viable; see memory).
5. Build → flash → **watch the panel** (simplefb) and/or serial. Finally see kernel messages.

## Assets on hand (all backed up)
- `device-facts/dt/stock-fdt.dtb` (842K, the real merged device tree — `dtc -I dtb -O dts` it for
  the complete hardware reference: clocks, regulators, GPIOs, panel timings, memory map).
- `device-facts/partitions-backup/super.img` (11GB) — vendor blobs: ath11k board files,
  Adreno a730 zap/firmware, audio firmware, `/vendor/firmware` (mount the super dynparts to
  extract). Extract with `lpunpack`/`simg2img` + loop-mount.
- `vendor_boot.img`, `boot.img`, `dtbo.img`, `vbmeta*.img` (stock) — reference + restore.
- Android restore: `root-build/android_restore.tar` (KernelSU boot + stock vendor_boot) +
  `vbmeta_disabled.tar`. Device currently on rooted Android, WiFi firewalled at UniFi.

## Downstream artifacts (keep for reference, not the active path)
`pmaports-overlay/device/downstream/{device,linux}-samsung-gts8pwifi` (built kernel + rootfs
work). The downstream kernel builds (docs/02 + the memory build-gotchas) — useful if we ever
want vendor drivers, but the mainline path is now primary.

---

## BUILT — ready to flash (2026-07-19, this session)

Mainline packages authored and building CLEANLY (no clang-12 nightmare — mainline arm64
builds with Alpine gcc). Kernel apk = `linux-postmarketos-qcom-sm8450-6.13_rc3-r0.apk`
(21.8 MB, 667 modules, kernel.release `6.13.0-rc3-next-20241220-sm8450`).

Packages live in the ACTIVE aports at `pmb-work/cache_git/pmaports/device/testing/`:
- `linux-postmarketos-qcom-sm8450/` — APKBUILD + `pmos.config` + `sm8450-samsung-gts8pwifi.dts`.
  Source = **sm8450-mainline/linux next-new** commit `bf1d29fced6e156` (6.13-rc3). Config is
  generated in prepare(): `make defconfig sm8450.config` (the tree's own fragment) + merge
  `pmos.config`. Build = `make Image.gz modules dtbs`.
- `device-samsung-gts8pwifi/` (pkgrel=3, mainline; the old downstream one was REMOVED from the
  active tree — still preserved in `pmaports-overlay/device/downstream/`).

**Key config choice (pmos.config): `CONFIG_DRM_MSM=n` for the FIRST boot.** simpledrm owns the
panel console the whole boot (our S6TUUM1 DDIC has no mainline driver to evict it). Also set:
DRM_SIMPLEDRM=y, DRM_FBDEV_EMULATION=y, FRAMEBUFFER_CONSOLE=y, SERIAL_QCOM_GENI_CONSOLE=y,
USB gadget configfs. **Next step after boot is confirmed: flip DRM_MSM=m** to start the real
display stack.

DTB verified (dtc round-trip): framebuffer@b8000000 width=1752 height=2800 stride=7008
a8r8g8b8 + splash-region reserved. cmdline baked into vendor_boot:
`earlycon=qcom_geni,0x0099c000 console=ttyMSM0,115200n8 console=tty0 loglevel=8 PMOS_NO_OUTPUT_REDIRECT`.

### Flash artifacts (in `root-build/`, built by `pmb install --split` + `pmb export`)
- `pmos_mainline_ap.tar` = **boot.img + vendor_boot.img** (mainline kernel + our DTB + cmdline).
- `pmos_mainline_userdata.tar` = 865 MB rootfs (ext4, UUID a4348702… = pmos_root_uuid; initramfs
  finds root by UUID, resizes on first boot). Raw copies in `root-build/mainline/`.
- `vbmeta_disabled.tar` = disables dm-verity (reuse from before).

### Flash recipe (device in Download mode, PID 04e8:685d)
```
odin4 -a root-build/pmos_mainline_ap.tar \
      -u root-build/pmos_mainline_userdata.tar   # then separately, or same call:
odin4 ... vbmeta_disabled.tar
```
odin matches each image in a tar to its partition BY FILENAME, so boot.img→boot,
vendor_boot.img→vendor_boot, userdata.img→userdata, vbmeta.img→vbmeta. NEVER any
bootloader/secure-world partition. Then **watch the panel** for the simplefb kernel log.

### Why this should break the blindness (vs downstream)
Downstream: console=null, no FB driver, kernel refused our initramfs, zero output. Mainline:
simple-framebuffer paints fbcon straight onto the bootloader-lit panel at 0xb8000000, and
earlycon prints on the geni UART from the first instruction — visible boot by construction.
