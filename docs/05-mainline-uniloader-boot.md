# Phase 3 — MAINLINE LINUX BOOTS (uniLoader path)

**Status: 2026-07-19 — mainline Linux 6.13-rc3 boots the SM-X800 all the way to a
postmarketOS login prompt (`samsung-gts8pwifi login:`). 8 cores, readable console on
the panel, UFS storage, root mounted, systemd stage 2, getty.**

The port works. What remains is peripheral bring-up — above all **input**: there is
no working keyboard, touchscreen, or USB, so the login prompt cannot be typed at.
See §8 and §10.

Boot chain that works:
```
ABL -> "press power to confirm unverified firmware boot" (MUST press Power)
    -> uniLoader (own simplefb console; prints its banner)
    -> mainline kernel + OUR untouched DTB
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

Upstream: `github.com/ivoszbg/uniLoader` (has SM8450 + `r0q_defconfig` already).
Our port (3 small files, in `reference/uniLoader/`):

- `board/samsung/board-gts8pwifi.c` — a simplefb definition and nothing else.
- `board/Kconfig` — `config SAMSUNG_GTS8PWIFI`, `depends on SM8450`.
- `board/Makefile` — `lib-$(CONFIG_SAMSUNG_GTS8PWIFI) += samsung/board-gts8pwifi.o`
- `configs/gts8pwifi_defconfig` — copy of `r0q_defconfig` with our board symbol.
  Addresses were kept from r0q and they WORK:
  `TEXT_BASE=0x87000000  PAYLOAD_ENTRY=0x80b900000  RAMDISK_ENTRY=0xb6915000`
  (`0x80b900000` is not a typo — it is `0x8_0b900000`, in the upper DRAM bank, which
  our memory map also has.)

Build (needs a host gcc for kbuild's fixdep, plus an aarch64 cross toolchain — the
pmbootstrap chroot has both):

```sh
# blobs: kernel must be UNCOMPRESSED Image
gunzip -c vmlinuz > blob/Image
cp sm8450-samsung-gts8pwifi.dtb blob/dtb
cp initramfs blob/ramdisk
make ARCH=aarch64 CROSS_COMPILE=aarch64-alpine-linux-musl- gts8pwifi_defconfig
make ARCH=aarch64 CROSS_COMPILE=aarch64-alpine-linux-musl-
# -> ./uniLoader  ("Linux kernel ARM64 boot executable Image" — it masquerades as a kernel)
```

NOTE: `pmb build` zaps the chroot, so reinstall the toolchain each time:
`./pmb chroot -- apk add build-base gcc-aarch64 binutils-aarch64 make bison flex`

## 3. Packaging the boot image

Stock kernel is a RAW uncompressed Image, so use raw `uniLoader` (not `uniLoader.gz`).
Take the stock boot.img's own mkbootimg args and just substitute the kernel:

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
| 4 | No bootargs anywhere | would inherit stock `console=null` | put bootargs in DTS `/chosen` |
| 5 | Display torn down mid-boot | screen paints then goes black | `clk_ignore_unused pd_ignore_unused` |
| 6 | simplefb didn't hold display | framebuffer became raw memory noise | give simplefb `clocks` + `power-domains` |
| 7 | UFS not enabled | no block devices, can't mount rootfs | enable `&ufs_mem_hc` / `&ufs_mem_phy` |

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
`/memory`** (it only injects `linux,initrd-start`/`-end` into `/chosen`). The kernel
got zero bytes of RAM and panicked instantly, before any console. Completely silent.
Fix: `/delete-node/ memory@a0000000;` and hardcode the real banks from the stock DTB.

### 4.4 Keeping the display alive
Two separate things were needed:
- `clk_ignore_unused pd_ignore_unused` on the cmdline — otherwise the kernel's
  late-boot "disable everything unused" sweep gates the display clocks and the panel
  goes black mid-boot. Log confirms: `clk: Not disabling unused clocks`,
  `PM: genpd: Not disabling unused power domains`.
- **simplefb must declare the display `clocks` and `power-domains`.** simpledrm
  acquires and HOLDS them (see `simpledrm_device_release_clocks` /
  `simpledrm_device_detach_genpd` in the kernel). Without them nothing owns the
  display block, the bootloader's scanout is torn down, and the framebuffer
  degenerates into ordinary RAM — which renders on-panel as accumulating garbage,
  exactly "a binary file opened in an image viewer".

## 5. odin4 flashing lessons (hard-won, cost many cycles)

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

## 6. Boot flow that works

```
ABL -> "press power button to confirm unverified firmware boot"  (MUST press Power)
    -> uniLoader (simplefb console on panel, prints its banner)
    -> jumps to mainline kernel with OUR untouched DTB
    -> kernel boots, 8 penguins, readable log, pmOS initramfs
```

`fbcon=font:TER16x32` + `CONFIG_FONT_TER16x32=y` makes the log legible at 2800px wide
(the default 8x16 font gives ~350 columns and photographs as unreadable noise —
which genuinely cost us time, because we could not tell a real boot log from
framebuffer garbage).

## 7. UFS (built, not yet verified on device)

Neither `sm8450-samsung-r0q.dts` nor our original skeleton enabled UFS, so there were
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

**UUID GOTCHA:** the rootfs UUID is baked into `bootargs` in the DTS. Re-running
`pmb install` regenerates the rootfs with a NEW UUID. The currently-flashed userdata is
`a4348702-8917-409c-8b8d-ae162bbcc969`. If you reflash userdata, update the DTS to match.

## 8. Known gaps / next up

- **USB enumerates nothing, in EITHER direction.** Key finding: **host mode cannot
  work** until Type-C / `pmic_glink` is described in the DTS — in host mode the tablet
  must supply 5V VBUS to the peripheral and nothing switches it, so a bus-powered
  keyboard never gets power regardless of dwc3. Gadget mode (PC supplies VBUS) is the
  achievable path; currently `&usb_1_dwc3 { dr_mode = "peripheral"; phys =
  <&usb_1_hsphy>; }` with the SS phy left out, and still nothing enumerates.
- **Input: nothing at all.** Log shows `couldn't open /dev/input/: No such file or
  directory` repeatedly. Touchscreen (STM `stm_ts`) has no mainline driver; the
  magnetic Book Cover Keyboard is unported. So the debug shell is currently
  look-but-don't-touch.
- **USB gadget failed:** `dwc3 a600000.usb: Configuration mismatch. dr_mode forced to
  gadget`, `dwc3: failed to initialize core`, `can't open .../usb_gadget/g1/UDC`,
  `Couldn't write new UDC`. Getting this up is the highest-value next step — it gives
  a keyboard-free way in (SSH/telnet over USB networking).
- Deferred probes seen: `rx_macro`/`tx_macro` (unable to get macro clock),
  `qcom-sm8450-lpass-lpi-pinctrl`, `1dfa000.crypto` sync_state.
- `DRM_MSM=n` currently (deliberate, so simpledrm owns the panel). Real display stack
  and the S6TUUM1 panel driver are much later work.

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

**UUIDs:** every `pmb install` regenerates them, and ours are baked into the DTS
bootargs (uniLoader sets no cmdline). After any install, read the fresh values from
boot-deploy and update the DTS or the initramfs will not find root:

```sh
strings <pmb-work>/chroot_rootfs_<device>/boot/vendor_boot.img | grep pmos_root_uuid
```

**Build-order trap:** `pmb build --force` zaps chroots and DELETES the rootfs image in
`chroot_native/home/pmos/rootfs/`. Since the kernel needs UUIDs that only exist after
`pmb install`, the order must be: install → copy the .img out to safety → read UUIDs →
patch DTS → build kernel → build uniLoader. Preserve the initramfs too.

## 9. Package/versions at time of writing

- `linux-postmarketos-qcom-sm8450` 6.13_rc3-r7, source `sm8450-mainline/linux`
  `next-new` @ `bf1d29fced6e156dd6090a9b6600a8c44259c114`. Config generated in
  prepare(): tree `defconfig` + `sm8450.config` fragment + our `pmos.config`.
- `device-samsung-gts8pwifi` 0.1-r5 (mainline, `device/testing/`).
- Kernel reports: `6.13.0-rc3-next-20241220-sm8450`.
- Mainline builds cleanly with Alpine gcc — none of the clang-12 pain from downstream.
