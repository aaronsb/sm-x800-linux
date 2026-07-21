# Phase 2 — pmOS Port: Prepared State & Playbook

Everything staged so next session starts at `pmbootstrap init`, not from zero.

## Strategy
**Downstream-first** (akm-04 gts8x 5.10 kernel — *proven to boot on this exact hardware* via the KernelSU flash), not mainline. Fastest path to a first boot with working display/touch/wifi (vendor drivers present). Migrate toward mainline later (Phase 3+).

## Already done (host state)
- **pmbootstrap 3.11.1** at `tools/pmbootstrap/`; wrapper **`./pmb <cmd>`**.
- **pmaports cloned** (234 MB) at `pmb-work/cache_git/pmaports` — the slow git fetch is done.
- Work dir: `pmb-work/` (config `~/.config/pmbootstrap_v3.cfg`: channel `systemd-edge`, UI `console`, systemd yes; device still placeholder `qemu-amd64` — gets set during real `init`).
- `.gitignore` excludes `pmb-work/`, `firmware/`, big binaries.
- **odin4 flash pipeline validated** (Phase 1). Samsung download mode, no fastboot.
- **stock boot.img** unpacked at `root-build/work/` (and `root-build/stock_boot.img`): header **v4**, pagesize **4096**, kernel raw, ramdisk lz4_legacy, cmdline **empty**, base os 12. Feed this to `pmbootstrap bootimg_analyze` to auto-fill flasher offsets.

## Kernel source (for `linux-samsung-gts8pwifi` APKBUILD)
- Repo: `https://github.com/akm-04/Samsung_Kernel_sm8450_common_gts8x.git`
- **Pin to the V1.0 release** (`5.10.226_gts8x`, tag/commit of the KernelSU build we KNOW boots) rather than the moving `A15_gts8u_msm-kernel` branch (commit ea029a8, 2026-07-02) — consistency with the proven-good kernel.
- Defconfigs present: `gts8uwifi-waipio_defconfig` (Ultra) + a `vendor/` dir. **No gts8p-specific defconfig seen at top level** — use `gts8uwifi-waipio_defconfig` (same SoC) or hunt `vendor/` for a gts8p variant; adapt.
- Kernel is 5.10 GKI, built from Samsung OSRC One UI 7 source.

## Mainline-track reference (for LATER, Phase 3+)
`github.com/sm8450-mainline/pmaports` — the sm8450-mainline community's pmaports fork; on-target for when we migrate from downstream to a mainline sm8450 kernel. Has sm8450 device configs to reference. (Downstream-first now; this is the migration target.)

## Reference devices in pmaports (copy their APKBUILD/deviceinfo)
`pmb-work/cache_git/pmaports/device/downstream/`: **device-samsung-a51**, **device-samsung-beyond1lte**, device-samsung-a32, device-samsung-m20lte — all Samsung downstream, **heimdall flash method** = our exact pattern. Copy deviceinfo + kernel APKBUILD structure from one of these (beyond1lte/a51 are good, similar-era Snapdragon).

## The `pmbootstrap init` new-device flow (from wiki)
Running `./pmb init` and entering a codename not in pmaports triggers **new-device port generation**. Answers for gts8pwifi:
| Prompt | Answer |
|---|---|
| work path | keep `pmb-work` (already set) |
| channel | edge (set) |
| vendor | `samsung` |
| codename | `gts8pwifi` |
| "new device port for samsung-gts8pwifi? Continue?" | **y** |
| kernel | **downstream** |
| architecture | **aarch64** |
| manufacturer / name / year | Samsung / Galaxy Tab S8+ / 2022 |
| chassis | **tablet** |
| external storage (sdcard)? | **y** (has microSD) |
| flash method | **heimdall** |
| boot.img to analyze | `root-build/stock_boot.img` (auto-fills offsets) |
| UI | `console` first (or xfce4 later) |

Generates: `pmb-work/cache_git/pmaports/device/downstream/device-samsung-gts8pwifi` + `linux-samsung-gts8pwifi`.
Note: `deviceinfo_kernel_cmdline*` is obsoleted → use `kernel-cmdline.d/` (pmaports!7708).

## Build + flash loop
1. Edit generated `linux-samsung-gts8pwifi/APKBUILD` → point at akm-04 V1.0 source + defconfig; add pmOS config requirements (framebuffer/DRM console, **USB gadget RNDIS/CDC** for `telnet 172.16.42.1` debug shell, DEVTMPFS). `./pmb kconfig check` / `./pmb kconfig edit linux-samsung-gts8pwifi`.
2. `./pmb build linux-samsung-gts8pwifi` (~20–30 min first time; watch `./pmb log` in another terminal).
3. `./pmb install` (build rootfs image).
4. Flash: get pmbootstrap's boot.img → `tar` it → `odin4 -a boot.tar -u root-build/vbmeta_disabled.tar` (reuse our vbmeta_disabled). Rootfs goes to userdata — confirm how pmOS deviceinfo handles A-only + dynamic super (may need a dedicated partition or userdata install; check beyond1lte deviceinfo).
5. **First-boot debug:** framebuffer console on the panel, and/or USB RNDIS → `telnet 172.16.42.1`. Iterate.

## Known gotchas
- SELinux **permissive** usually required for downstream Samsung.
- We flash `vbmeta_disabled` (verity off) — keep doing so.
- Downstream reuses Android vendor blobs from super/vendor; display likely works on downstream (vs mainline needs custom panel driver).
- Never flash bootloader partitions — Download mode stays the backstop.
- FRP is active on the Android side (irrelevant — we're overwriting).

## Canonical docs (wiki is Anubis-walled to headless fetch; use real Chrome)
- wiki.postmarketos.org/wiki/Porting_to_a_new_device (+ /Generating_device-specific_packages, /Kernel_package) — captured in `docs/wiki-porting-*.md`
- docs.postmarketos.org/pmaports (deviceinfo reference — fetchable)
