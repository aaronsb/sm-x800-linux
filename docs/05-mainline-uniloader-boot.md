# Phase 3 — MAINLINE LINUX BOOTS (uniLoader path)

**Status: 2026-09-22. Vanilla kernel 7.2 from kernel.org (package 7.2-r28) boots
the SM-X800 through uniLoader into postmarketOS**, with input, USB host, the
native display stack and the GPU up (docs/07 and 08). uniLoader owns the kernel
command line: the port is a pinned upstream commit plus four git-generated
patches (§2), it sets `/chosen/bootargs` from a blob the build writes, and the
tablet's `/proc/cmdline` ends in `bootloader=uniloader`. The same day's reset
loop was an alignment fault in uniLoader's memcpy (§4.5). The build is one
ordered `make` sequence (§2.3).

The first login prompt (`samsung-gts8pwifi login:`) came on 2026-07-19 on
6.13-rc3, with nothing to type at it. This page keeps that story: why
uniLoader, what our port of it looks like, and every silent failure on the way.

Boot chain that works:
```
ABL -> "press power to confirm unverified firmware boot" (times out on its own; Power skips the wait)
    -> uniLoader (own simplefb console; prints its banner and "cmdline: ...")
    -> copies the DTB out of its own image, sets initrd + bootargs in /chosen
    -> mainline kernel + OUR DTB, untouched by ABL
    -> initramfs: UFS enumerates -> mdev makes /dev/disk/by-uuid
    -> subpartitions inside userdata (pmOS_boot + pmOS_root) -> root mounted
    -> jump_init_2nd -> systemd -> getty -> LOGIN PROMPT
```

---

## 1. The core discovery: you CANNOT boot mainline directly via Samsung's ABL

From the postmarketOS wiki page for our sibling device, Galaxy S22 `samsung-r0q`
(same SM8450 SoC), verbatim:

> "This device has trouble booting mainline Linux because Samsung uses device tree
> fragments, and the combined device tree can disrupt the boot process. To address
> this, we use a secondary bootloader called uniLoader... **Standard bootloaders are
> not supported. Only uniLoader will work here.**"

Samsung's ABL applies its own DTBO fragments onto whatever DTB it selects, which
corrupts a mainline device tree. The kernel then dies before any console exists.

We burned a lot of cycles proving this the hard way: we fixed ABL's DTB *selection*
(adding `qcom,msm-id`/`qcom,board-id`), and it still failed silently — because
selection was never the problem; the *overlay merge* is.

**uniLoader embeds kernel + DTB + ramdisk inside its own binary.** ABL only ever sees
"a kernel". It never gets a chance to touch our device tree. That is the whole point.

lk2nd does NOT support SM8450. uniLoader is the answer.

## 2. Our uniLoader port

Upstream: `github.com/ivoszbg/uniLoader` (has SM8450 + `r0q_defconfig` already),
pinned to commit `43770a04327532407194ddd3f9f35770daa01c70` (`UL_COMMIT` in the
Makefile). Everything of ours lives in `pmaports-overlay/uniloader-port/`:

- `board/samsung/board-gts8pwifi.c` — a simplefb definition and nothing else.
- `configs/gts8pwifi_defconfig` — copy of `r0q_defconfig` with our board symbol.
  Addresses were kept from r0q and they WORK:
  `TEXT_BASE=0x87000000  PAYLOAD_ENTRY=0x80b900000  RAMDISK_ENTRY=0xb6915000`
  (`0x80b900000` is not a typo — it is `0x8_0b900000`, in the upper DRAM bank, which
  our memory map also has.) `DTB_RELOCATE=y` with `DTB_ENTRY=0xb6000000`,
  `CMDLINE_BLOB=y`, and `COMPRESS_GZIP` off: the `.gz` output was never used,
  the boot image always carried the raw `uniLoader` binary (§3).
- `cmdline.in`: the kernel command line, one string with `@BOOT_UUID@` and
  `@ROOT_UUID@` placeholders (§2.1).
- `patches/`: every change to an upstream file, as git-generated patches
  (`tools/mkpatch`, never hand-written), applied in name order by `make deps`:

| Patch | What it does |
|---|---|
| `0001-dtb-relocate` | `DTB_RELOCATE`/`DTB_ENTRY`: copy the embedded DTB out of the loader image before handing it to the kernel. uniLoader loads at `0x87000000` and its 30 MiB image put the DTB at `0x88cd6000`, inside the SLPI carve-out at `0x88000000`; the kernel reserves the DTB first, the carve-out then fails to reserve, and the SLPI cannot probe. The copy goes to `0xb6000000`, plain RAM below the ramdisk copy (commit 84de076) |
| `0002-cmdline-blob` | `CMDLINE_BLOB`/`CMDLINE_PATH`: link `blob/cmdline` into a `.cmdline` section and set `/chosen/bootargs` from it (§2.1) |
| `0003-board-gts8pwifi-registration` | `SAMSUNG_GTS8PWIFI` in `board/Kconfig` and the `board/Makefile` line, so the board builds with no manual edit of either file |
| `0004-memcpy-strict-align` | keep memcpy/memmove aligned with the MMU off, `-mstrict-align` for C (§4.5) |

Two board files are copied into the clone, the rest is patched; the old manual
step (append the registration lines yourself) is gone. `make deps` applies each
patch when it applies cleanly, reports it as already applied when it applies in
reverse, and stops on anything else.

### 2.1 The kernel command line

uniLoader upstream injects `linux,initrd-start`/`-end` into `/chosen` and
nothing else, so the command line first lived in the DTS `bootargs` (bug 4 in
§4), and every change to it meant a kernel package rebuild. Patch 0002 moves it
into uniLoader: `blob/cmdline` is linked next to the ramdisk, and after the
ramdisk handler has opened the DTB, `drivers/cmdline-handler.c` copies the blob
into a bounded buffer, prints it once as `cmdline: ...`, and sets
`/chosen/bootargs`. An empty blob leaves the DTB's bootargs alone, and a
failure to set the property is reported and the boot continues with the DTB's
own value. The build creates an empty `blob/cmdline` when the file is absent,
because `ld` refuses a missing `INPUT`.

The Makefile's `cmdline-blob` target writes the blob: `cmdline.in` with the two
UUIDs filled from the rootfs `vendor_boot` header, then `bootloader=uniloader`,
then `BOOTARGS_EXTRA` when set, NUL-terminated. On the tablet `/proc/cmdline`
ends in `bootloader=uniloader`, which is the proof that the blob and not the DTS
supplied it. The DTS `/chosen/bootargs` still carries the same tokens for now;
dropping it is the follow-up (kernel pkgrel 29), and until then the `uuids` gate
(§7) keeps the two copies in agreement.

### 2.2 Building it

uniLoader needs a host gcc for kbuild's fixdep plus an aarch64 cross toolchain;
the pmbootstrap chroot has both. `make uniloader` does the following, and
`make deps` re-installs the toolchain because `pmb build` zaps the chroot:

```sh
# blobs: kernel must be UNCOMPRESSED Image
gunzip -c vmlinuz > blob/Image
cp sm8450-samsung-gts8pwifi.dtb blob/dtb
cp initramfs blob/ramdisk
# blob/cmdline from cmdline-blob (above)
make ARCH=aarch64 CROSS_COMPILE=aarch64-alpine-linux-musl- gts8pwifi_defconfig
make ARCH=aarch64 CROSS_COMPILE=aarch64-alpine-linux-musl-
# -> ./uniLoader  ("Linux kernel ARM64 boot executable Image" — it masquerades as a kernel)
```

The kernel apk is chosen by the APKBUILD's `pkgver-pkgrel`, never by the newest
file in the package cache, and its path is recorded in `.stage/kernel-apk` for
`install-tablet` to check against (§5b).

### 2.3 The build as a sequence

The Makefile is ordered; each step checks what the previous one left behind and
names the step to run when something is missing:

```
make check          host tools, pmbootstrap init, uniLoader pin, dumps, harvest, apks;
                    reports "ready for make boot / make install-tablet" until
                    make rootfs has produced root-build/combined.img, which the
                    sparse userdata tar at the end of make image is built from
make deps           one-time: uniLoader clone + patches, chroot toolchain
make dumps          verify the stock dumps (boot, apnhlos, super) by sha256;
                    ADB=1 pulls the missing ones from a tablet rooted on stock
make harvest        proprietary blobs and sensor configs out of the dumps (docs/09)
make rootfs         pmb install; preserves the combined image, prints the UUIDs
make image          uuids gate -> kernel -> device -> boot -> sparse userdata tar
make flash-all      first install: boot + userdata in ONE odin session (§5)
make install-tablet later kernels: dd boot.img + apk add over ssh, reboot (§5b)
```

Variants: `boot-debug` rebuilds uniLoader with `pmos.debug-shell` appended to
the command line and writes `boot-debug.img` and its tar beside the normal
artifacts; `kernel`, `device` and `boot` run one stage of `image`.

## 3. Packaging the boot image

Stock kernel is a RAW uncompressed Image, so the boot image carries the raw
`uniLoader` binary; the defconfig no longer builds a `.gz` at all. Take the stock
boot.img's own mkbootimg args and just substitute the kernel (`make bootimg`):

```sh
mkbootimg --header_version 4 --os_version 12.0.0 --os_patch_level 2025-04 \
  --kernel uniLoader --ramdisk <stock ramdisk> --cmdline '' -o boot.img
```

`unpack_bootimg --boot_img <stock> --format=mkbootimg` prints those args for you.
Preserve `os_version`/`os_patch_level` (anti-rollback, the download screen shows `AR:2`).

**Restore the STOCK vendor_boot.** uniLoader carries its own DTB and ramdisk, so a
custom vendor_boot is unnecessary and is a source of interference.

## 4. The bug chain we fixed (each one was a silent, invisible failure)

| # | Bug | Symptom | Fix |
|---|-----|---------|-----|
| 1 | Wrong load addresses | kernel never runs, falls back to download | see below |
| 2 | Framebuffer geometry transposed | text rendered diagonally sheared | 2800x1752, NOT 1752x2800 |
| 3 | `/memory` node had size 0 | instant silent panic after "Booting kernel..." | hardcode real banks |
| 4 | No bootargs anywhere | would inherit stock `console=null` | put bootargs in DTS `/chosen`; since 2026-09-22 uniLoader sets them from `blob/cmdline` (§2.1) |
| 5 | Display torn down mid-boot | screen paints then goes black | `clk_ignore_unused pd_ignore_unused`; retired in DTS r40 once the msm DPU/DSI and GPU drivers owned their clocks (§4.4) |
| 6 | simplefb didn't hold display | framebuffer became raw memory noise | give simplefb `clocks` + `power-domains` |
| 7 | UFS not enabled | no block devices, can't mount rootfs | enable `&ufs_mem_hc` / `&ufs_mem_phy` |
| 8 | Unaligned memcpy with the MMU off | reset loop before "Booting kernel" once the command line blob existed | byte loop for unaligned copies, `-mstrict-align` (§4.5) |

### 4.1 Load addresses — and a boot-deploy trap
Stock expects **base `0x00000000`**: kernel `0x00008000`, ramdisk `0x02000000`,
tags `0x01e00000`, dtb `0x01f00000`. mkbootimg's DEFAULT base is `0x10000000`, which
put everything `0x10000000` too high.

**TRAP:** boot-deploy only passes `--base`/`--*_offset` to mkbootimg on the legacy
(header <= v2) path. For header v3/v4 it omits them entirely, so
`deviceinfo_flash_offset_*` are silently IGNORED. The only way to set them for v4:

```
deviceinfo_bootimg_custom_args="--base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x02000000 --tags_offset 0x01e00000 --dtb_offset 0x01f00000"
```
(Mostly moot on the uniLoader path, which uses stock vendor_boot anyway — but it is a
real trap for anyone doing v4 images with pmbootstrap.)

### 4.2 Framebuffer geometry — the touchscreen lies
Scanout is **LANDSCAPE 2800 wide x 1752 tall**, stride `2800*4 = 11200`, `a8r8g8b8`,
at `0xb8000000`. Evidence: stock `qcom,mdss-pan-physical-width/height-dimension` =
267mm x 167mm, ratio 1.60 = 2800/1752.
**Do NOT use `sec,max_coords = <0x6d8 0xaf0>` (1752x2800)** — that is the touchscreen's
portrait coordinate space, not the display scanout. Using it renders correctly-sized
but diagonally sheared text (each row slipping by 2800-1752 px).

### 4.3 The zero-RAM panic
`sm8450.dtsi` ships a placeholder `memory@a0000000` with `reg = <0 0xa0000000 0 0>`
— size ZERO — expecting the bootloader to patch it. **uniLoader does not patch
`/memory`** (it injects `linux,initrd-start`/`-end` and, since patch 0002,
`bootargs` into `/chosen`, nothing else). The kernel
got zero bytes of RAM and panicked instantly, before any console. Completely silent.
Fix: `/delete-node/ memory@a0000000;` and hardcode the real banks from the stock DTB.

### 4.4 Keeping the display alive
Two separate things were needed in the simpledrm era:
- `clk_ignore_unused pd_ignore_unused` on the cmdline — otherwise the kernel's
  late-boot "disable everything unused" sweep gates the display clocks and the panel
  goes black mid-boot. Log confirms: `clk: Not disabling unused clocks`,
  `PM: genpd: Not disabling unused power domains`. Retired in DTS r40: the msm
  DPU/DSI/panel and GPU drivers now own their clocks and domains, and keeping
  every unclaimed clock on forever costs power and masks PM bugs. The command
  line carries neither token today.
- **simplefb must declare the display `clocks` and `power-domains`.** simpledrm
  acquires and HOLDS them (see `simpledrm_device_release_clocks` /
  `simpledrm_device_detach_genpd` in the kernel). Without them nothing owns the
  display block, the bootloader's scanout is torn down, and the framebuffer
  degenerates into ordinary RAM — which renders on-panel as accumulating garbage,
  exactly "a binary file opened in an image viewer".

### 4.5 The alignment fault (2026-09-22)

The first boot with a command line blob reset before uniLoader printed
"Booting kernel...", and kept resetting. ABL hands the CPU to uniLoader with the
MMU off, so every data access is to Device-nGnRnE memory, where an unaligned
access is an Alignment fault. `arch/aarch64/memcpy.S` is the Arm
optimized-routines copy and assumes unaligned access is allowed: for counts over
128 it finishes by loading and storing the last 64 bytes relative to the end of
the region. The kernel and DTB copies never reach that case (page-aligned bases,
counts that are multiples of 16). The 253-byte command line copy in
`cmdline_handler_patch_dtb` did, and faulted at `cmdline + 189` with
`ESR_EL1 0x96000021`.

Patch 0004 makes memcpy and memmove take a byte loop, backwards when the
destination overlaps the source, unless src, dst and count are all multiples of
8; the aligned case keeps the existing code. C code is built with
`-mstrict-align` so the compiler cannot introduce the same access pattern.

The fault was reproduced off the tablet with `tools/uniloader-fdt-harness`
(its README records the runs): uniLoader's own libfdt, string routines and
`memcpy.S` built into a freestanding binary for `qemu-system-aarch64 -M virt`
with the MMU off. The upstream `memcpy.S` faults there at the same instruction;
the patched one passes every step, and the user-mode build under `qemu-aarch64`
shows with `dtc` that only the initrd properties and `bootargs` changed. libfdt
was not involved: uniLoader's `fdt_rw.c` uses a byte-loop `__optimized_memmove`,
and the asm memmove is overlap-safe as well.

## 5. odin4 flashing lessons (hard-won, cost many cycles)

- **Stage the recovery image before the first flash of a new bootloader.** A
  uniLoader that faults before the kernel gives a reset loop and nothing else.
  Keep the `pmos_uniloader_boot.tar` of a known-good build; download mode is
  power off, then Vol Up + Vol Down, plug USB, then
  `odin4 -a root-build/pmos_uniloader_boot.tar` from that build.

- **userdata MUST be a sparse image.** A raw ext4 image fails at ~3-4% with
  `Fail request receive 3` regardless of cable/hub. Convert first:
  `img2simg root.img userdata.img` (device then reports `set warranty bit: Sparse`).
- **odin needs a FRESHLY-ENTERED download session.** A session that has been sitting
  through boot-attempt cycles fails with `FAIL! (Auth)` — and the "an error has
  occurred while updating the device software" screen *enumerates as `04e8:685d` and
  `odin4 -l` finds it*, but will not authenticate a real flash. The user aptly called
  it "fake download mode". Re-enter properly: Vol-Down+Power to black, then hold BOTH
  volume keys to the Warning screen, Vol-Up to confirm.
- **A failed transfer wedges the session** — the next `Setup Connection` times out
  until the device is rebooted back into download mode.
- **Avoid deep USB hubs.** Ours was 2 hubs deep (`usb 3-3.4.4`) and unstable; a direct
  port (`usb 1-1`) was far more reliable.
- Flash with everything in one AP tar; odin matches images to partitions BY FILENAME:
  `tar -H ustar -cf ap.tar boot.img vendor_boot.img vbmeta.img`

## 5b. Updating a running port without download mode

`make install-tablet` writes a new kernel to the tablet over ssh: `dd` of
`boot.img` to `/dev/disk/by-partlabel/boot`, `cmp` against the image, `apk add`
of the kernel apk (and the device and temp/ apks), then reboot (`NOREBOOT=1`
skips it). It refuses when `.stage/kernel-apk` is not the apk the overlay
APKBUILD names, so a stale uniLoader build never goes out with a fresh apk.

- **A flash is two things.** Kernel modules live in the rootfs, not in boot.img.
  `dd` alone replaces kernel, DTB and initramfs; without the matching `apk add`
  the old `.ko` files stay under `/lib/modules` and a changed module never binds.
- **The UFS LUN order is not stable across boots.** The boot partition was
  `/dev/sda25` on one boot and `/dev/sdb25` on the next. Address it as
  `/dev/disk/by-partlabel/boot`, never a hardcoded `sdX`. The tell is `cmp`
  failing against every image at once.

## 6. A legible console

`fbcon=font:TER16x32` (still in the command line, now uniLoader's blob) +
`CONFIG_FONT_TER16x32=y` makes the log legible at 2800px wide
(the default 8x16 font gives ~350 columns and photographs as unreadable noise —
which genuinely cost us time, because we could not tell a real boot log from
framebuffer garbage).

## 7. UFS

Root has been on UFS since the first login prompt. Neither
`sm8450-samsung-r0q.dts` nor our original skeleton enabled it, so there were
NO block devices and the initramfs failed with
`ERROR: failed to mount subpartitions!` and dropped to the debug shell.

Added (supplies follow `sm8450-hdk.dts`), plus `vreg_l6b_1p2`/`vreg_l7b_2p5`/
`vreg_l9b_1p2` LDOs and the `vdd-l6-l9-l11-supply` parent rail on pm8350:

```dts
&ufs_mem_hc {
	status = "okay";
	vcc-supply = <&vreg_l7b_2p5>;      vcc-max-microamp = <1100000>;
	vccq-supply = <&vreg_l9b_1p2>;     vccq-max-microamp = <1200000>;
	vdd-hba-supply = <&vreg_l9b_1p2>;
};
&ufs_mem_phy {
	status = "okay";
	vdda-phy-supply = <&vreg_l5b_0p88>;
	vdda-pll-supply = <&vreg_l6b_1p2>;
};
```
`reset-gpios` deliberately omitted (HDK's `<&tlmm 210>` is board specific; the stock
DTB exposes no UFS reset line for this tablet).

**UUID GOTCHA:** re-running `pmb install` regenerates the rootfs with NEW UUIDs.
The command line blob picks them up from the rootfs `vendor_boot` header on every
`make uniloader`, so uniLoader always hands the kernel the flashed image's values.
The DTS `bootargs` still carries a copy (§2.1), and `make image` starts with the
`uuids` gate: it compares the rootfs values against the DTS, exits 1 on a
mismatch, and prints the two lines to change. A mismatch there is the most
common reason a freshly flashed system drops to the initramfs debug shell.

## 8. What the first boot left open, and where it closed

The 2026-07-19 boot had no input, no USB in either direction, deferred LPASS
probes and `DRM_MSM=n` so simpledrm could own the panel. All of it is resolved:
touchscreen, Book Cover Keyboard and USB host with VBUS from the MAX77705 in
docs/07; the native DPU/DSI/DSC stack and the S6TUUM1 panel driver in docs/08
(`pmos.config` sets `DRM_MSM=y`; a later line wins over the earlier `=n` that
still carries the first-boot comment); the LPASS probes in docs/10. The gadget
path remains open (README status table).

## 8b. Partition layout — userdata must hold the COMBINED image

This is not optional and cost a lot of debugging. The pmOS stage-1 init does:

```sh
mount_subpartitions      # find a partition containing exactly 2 subpartitions
wait_boot_partition      # needs pmOS_boot
mount_boot_partition /boot
extract_initramfs_extra /boot/initramfs-extra
jump_init_2nd
```

So pmOS needs **both** a `pmOS_boot` and a `pmOS_root`. Our real boot partition is
occupied by uniLoader, so both must live *inside* userdata. That means:

- Use `pmb install` **WITHOUT `--split`** → produces one `<device>.img` containing a
  GPT with pmOS_boot + pmOS_root. Flash that (sparse!) to userdata.
- Flashing only the `--split` `-root.img` leaves no pmOS_boot; even once root is found
  the initramfs stalls at `wait_boot_partition` and drops to the debug shell.

**UUIDs:** every `pmb install` regenerates them. The build reads the fresh values
from the `vendor_boot` header in the rootfs chroot (the same source `make uuids`
prints) and writes them into the command line blob; the DTS copy has to be
updated by hand until it is dropped (§2.1, §7):

```sh
strings <pmb-work>/chroot_rootfs_<device>/boot/vendor_boot.img | grep pmos_root_uuid
```

**Build-order trap:** `pmb build --force` zaps chroots and DELETES the rootfs image in
`chroot_native/home/pmos/rootfs/`. `make rootfs` preserves it as
`root-build/combined.img`. The UUIDs only exist after `pmb install`, and only
uniLoader consumes them: after a rootfs change `make uniloader` (or `make boot`)
rebuilds the blob, no kernel rebuild is needed. `make image` still runs the
`uuids` gate against the DTS copy until that copy is dropped (kernel r29).

## 9. Package versions

- `linux-postmarketos-qcom-sm8450` 7.2-r28, the vanilla release tarball from
  kernel.org. Config generated in prepare(): tree `defconfig` + the `sm8450.config`
  fragment carried in the package + our `pmos.config`. The pin and bump procedure
  are in docs/06.
- `device-samsung-gts8pwifi` 0.1-r25 (`device/testing/`).
- uniLoader at `43770a04`, patches 0001-0004 (§2).
- First boot, 2026-07-19: `linux-postmarketos-qcom-sm8450` 6.13_rc3-r7 from
  `sm8450-mainline/linux` `next-new` @ `bf1d29fc`, device 0.1-r5, kernel reporting
  `6.13.0-rc3-next-20241220-sm8450`. Mainline built cleanly with Alpine gcc, none
  of the clang-12 pain from downstream.
