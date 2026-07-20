# postmarketOS Porting Guide (captured 2026-07-19)

Offline copy of the key pmOS wiki porting pages (the wiki is Anubis-bot-walled to headless fetch; captured via real Chrome). Source: wiki.postmarketos.org/wiki/Porting_to_a_new_device.

---

## Page 1 — Porting to a new device (overview)

Main steps:
1. Prepare device for flashing by unlocking the bootloader. ✅ (done)
2. Set up pmbootstrap on your computer. ✅ (done)
3. Create the device-specific packages.
4. If using a vendor (downstream) kernel, add the package for it.
5. Compile the kernel package (+ any patches to make it build).
6. Install the system and test.
7. Create a wiki page for the device.
8. Submit packages to pmaports.

**Device-specific packages:**
- `device-vendor-codename` — metadata; contains `deviceinfo` (model, screen, flash method…) and optional config files (udev, ALSA UCM). Makes the device show in `pmbootstrap init`.
- `linux-vendor-codename` — builds the kernel + patches. (Mainline SoCs use a shared `linux-postmarketos-...` instead.)
- `firmware-vendor-codename` — firmware blobs (WiFi/BT); not needed for initial port.

Packages live in pmaports under `device/{category}` where category ∈ main/community/testing/downstream/archived. `pmbootstrap` generates a basic device + kernel package; manual edits still needed.

**Downstream vs mainline kernel:**
- Downstream (vendor) kernel: manufacturer's fork, old, assumes Android HAL/blobs → limited functionality on pmOS, but common starting point when SoC mainline support is poor. New downstream ports → `downstream` category.
- (Close-to) mainline: upstream-based, more features possible (GPU accel), but needs SoC + component drivers upstream + a DTS written. Can take hours→months. New mainline ports → `testing` category.
- Decision: check Mainlining#Supported_SoCs. SM8450 HAS mainline support, BUT we deliberately choose **downstream-first** for fastest working display, then migrate.

---

## Page 2 — Generating device-specific packages

**Install pmbootstrap** (done from git). To update later: `pmbootstrap pull`.

**`pmbootstrap init`** — detects a new port when you give an unknown vendor/codename and generates the base packages. Prompts (default in brackets, Enter accepts):
- Work path (default `~/.local/var/pmbootstrap`; we use `pmb-work`). ext4 etc only, ~10 GB free.
- Release channel → **edge**.
- **Vendor** (lowercase manufacturer) + **codename**.
- "You are about to do a new device port for 'vendor-codename'. Continue? [y]" → **y**.
- Kernel: **downstream** or mainline.
- Architecture: **aarch64** (64-bit ARM).
- Manufacturer, Name, Year → deviceinfo metadata.
- Chassis: handset/**tablet**/laptop.
- External storage (sdcard)? y/n.
- **Flash method** (0xffff/fastboot/**heimdall**/mtkclient/none/rkdeveloptool/uuu): **heimdall** = Samsung Odin/Download mode.
- **Analyze a boot.img** to auto-fill flasher info: give path to a working boot.img (stock or TWRP), or skip and run `pmbootstrap bootimg_analyze path/to/boot.img` later. (Note: `deviceinfo_kernel_cmdline[_append]` obsoleted by `kernel-cmdline.d/`, pmaports!7708.)
- Then generates:
  - `.../pmaports/device/downstream/device-vendor-codename`
  - `.../pmaports/device/downstream/linux-vendor-codename`
- Usual setup Qs follow; UI → **xfce4** is a good first choice (we'll start with `console`).

**Watch logs live:** `pmbootstrap log` (also `~/.local/var/pmbootstrap/log.txt`).

---

## Page 3 — Kernel package (splitter)
Just links to Downstream-kernel / Mainline-kernel sub-pages (sub-page slugs reorganized; grab live next session). For downstream: edit the generated `linux-...` APKBUILD to point at the vendor source + defconfig, fix build, run `pmbootstrap kconfig check`.
