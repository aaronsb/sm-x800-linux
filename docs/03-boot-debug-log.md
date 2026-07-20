# Phase 2 Boot Debug Log — pmOS first-boot attempts (2026-07-19)

Chronological record of the first-boot debugging so the next session doesn't re-tread it.

## What works (the only booting config)
`kernelsu_boot.tar` = proven akm-04 KernelSU kernel Image + **stock** boot.img ramdisk,
with **stock** vendor_boot + **stock** dtbo → **boots rooted Android**. This is our recovery
baseline (`root-build/android_restore.tar` = KernelSU boot + stock vendor_boot).

## Confirmed hardware/boot facts
- Boot header **v4**, pagesize 4096. Partitions: `boot`=sda25, `vendor_boot`=sda27,
  `dtbo`=sda34 (259:18), `recovery`=sda26, `super`=sda28. **No `init_boot` partition.**
- `vendor_boot` (stock) = **20MB Android vendor_ramdisk** (lz4) + **1.72MB base DTB** +
  bootconfig + cmdline `...console=null bootconfig...`. Stock boot.img ramdisk = Android's
  3.14MB `/init` + first-stage dirs.
- Live merged DTB pulled from `/sys/firmware/fdt` → `device-facts/dt/stock-fdt.dtb` (842K,
  model "Samsung GTS8PWIFI PROJECT (board-id,04)", compatible qcom,waipio-mtp). This is the
  real working device tree.
- **Our from-source kernel is broken**: `/proc/version` shows the working kernel was built
  with **clang 12.0.8**; we built with Alpine clang ~17-19 → crashes ~1s into boot (bisected:
  our-kernel+stock-ramdisk = ~1s loop; proven-kernel+stock-ramdisk = boots). Also has
  SHADOW_CALL_STACK/BTI/PTR_AUTH on. Needs clang-12 to be usable.

## Attempt matrix (all flashed boot+vendor_boot+vbmeta_disabled via odin4)
| boot.img ramdisk | vendor_boot | result |
|---|---|---|
| stock (KernelSU) | stock | boots Android ✓ |
| pmOS (magiskboot lz4) | stock | ~4s reboot loop |
| pmOS | empty vendor_ramdisk (512B cpio) | hangs, no output |
| pmOS | debug cmdline (console=tty0), empty rd | hangs |
| pmOS (+instr loop→dtbo) | debug, empty rd | hangs, **dtbo NOT written** |
| pmOS | vendor_ramdisk = pmOS (gzip) + stock dtb | hangs, no USB, **dtbo NOT written** |
| pmOS (instr at /init line 2) | vendor_ramdisk = pmOS | hangs, **dtbo NOT written** |

## THE BLOCKER
**pmOS `/init` never executes** — an instrumentation loop injected at the *literal first line*
of `/init` (dump `dmesg` to the dtbo partition every 1s, via `mknod ... b 259 18`) left dtbo
**untouched (still stock overlay magic d7b7ab1e) across 4 attempts**. So the kernel boots but
does not run our initramfs. Root cause of the v4 ramdisk delivery not yet found. Manual
mkbootimg/magiskboot assembly is suspected (stock vendor_boot works; every rebuilt one fails).

## boot-deploy + format tests (2026-07-19, later) — WALL CONFIRMED
Escalated to pmbootstrap's authoritative v4 assembly and controlled every remaining variable;
**all still fail — pmOS `/init` never runs (dtbo recorder silent every time):**
- **boot-deploy v4** (`generate_bootimg=true`, `deviceinfo_dtb=stock-fdt`, android-tools dep,
  DTB shipped to /usr/share/dtb): produced clean boot.img (kernel only, RAMDISK_SZ 0) +
  vendor_boot.img (gzip pmOS vendor_ramdisk + 842K merged DTB + cmdline w/ pmos_boot_uuid/
  pmos_root_uuid). Swapped proven kernel in. Flashed → hang, no USB, **dtbo untouched**.
- **boot-deploy layout + instrumented ramdisk** (line-1 recorder) → **dtbo untouched**.
- **lz4_legacy format hypothesis**: rebuilt vendor_boot with STOCK recipe (stock offsets
  0x00008000/0x02000000, stock 1.72M base DTB, stock bootconfig) + pmOS ramdisk compressed
  lz4_legacy (matching the stock ramdisk that boots) + kernel-only boot.img → **dtbo untouched**.

CONCLUSION: image assembly is NOT the cause (boot-deploy does it correctly and it still fails).
The proven kernel boots but refuses to execute ANY non-Samsung initramfs, in any slot, any
compression, any offset/DTB. Cannot diagnose further without a kernel-visible console. **Blind
downstream path is exhausted — next effort MUST be visibility-first (mainline earlycon/simplefb,
or a self-built kernel with a working console + FB_SIMPLE).**

## Why we're blind (the meta-problem)
- `console=null` in stock cmdline (Android bootloader adds it).
- No display driver in pmOS (Samsung DRM/techpack is an Android-loaded module) → panel frozen
  on splash, `console=tty0` shows nothing.
- No serial/UART access on the tablet.
- Samsung `/proc/last_kmsg` only persists the **bootloader** log (needs Android sec_debug
  cmdline params for the kernel portion) → never captured the pmOS kernel log.
- USB gadget never enumerated (pmOS `setup_usb_network` needs a UDC in /sys/class/udc; likely
  dwc3 not in peripheral mode without Android's setup, and `modprobe libcomposite` may be a
  module).

## Options for next session (pick one; visibility-first recommended)
1. **pmbootstrap `boot-deploy`, authoritative v4 assembly.** Provide `stock-fdt.dtb` as
   `deviceinfo_dtb`, re-enable `generate_bootimg`, let boot-deploy build boot.img+vendor_boot
   correctly, then magiskboot-swap the proven kernel into the result. Removes hand-assembly as
   a variable.
2. **Get a console via simple-framebuffer.** Find the bootloader cont_splash framebuffer
   (phys addr/geometry) in the stock DTB, add a `simple-framebuffer` node, ensure the kernel
   has FB_SIMPLE → fbcon on the panel = visible boot. Needs a kernel with FB_SIMPLE built-in.
3. **Pivot to mainline (r0q/sm8450-mainline).** Mainline gives `earlycon` + simplefb console
   out of the box (the pmOS-recommended path for exactly this blind situation), and we now have
   the DTB + all vendor blobs (`super.img`) to work from. Bigger lift, but VISIBLE.
4. **Fix our from-source kernel** (clang-12 toolchain in the pmbootstrap build) so we control
   the config (enable FB_SIMPLE, drop console=null handling, etc.).

## Assets captured this session (all backed up, device-facts/partitions-backup/)
super.img (11G, valid LP), vendor_boot.img, boot.img, dtbo.img, vbmeta*.img (stock),
vendor_boot_pmos*.img (rebuilds), stock-fdt.dtb, last_kmsg dumps. Root re-established via
KernelSU Manager v1.0.5 + `com.android.shell` granted root. FRP disarmed (Google account
removed). WiFi still blocked at UniFi (no OTA).
