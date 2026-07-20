# Phase 1 Runbook — Unlock → KernelSU root → dd backup

Device: SM-X800 (gts8pwifi), One UI 7 / X800XXU9DYDC. Host: Arch, `odin4` + artifacts in `root-build/`.

## Artifacts (all staged & verified)
| File | Purpose | Note |
|---|---|---|
| `root-build/kernelsu_boot.tar` | KernelSU boot → odin4 `-a` (AP) | stock boot.img (sliced from firmware) + akm-04 KernelSU kernel, magiskboot-repacked |
| `root-build/vbmeta_disabled.tar` | disable verity/verification → odin4 `-u` (UMS) | self-generated, avbtool `--flags 3` |
| `root-build/stock_boot.tar` | **restore insurance** → `odin4 -a stock_boot.tar` | pristine stock boot; puts stock kernel back |

## ⚠️ Irreversible points
- **Unlock (step 2)** = factory reset (wipe). Recoverable; does NOT trip Knox.
- **First flash (step 4)** = **trips Knox efuse permanently** (`warranty_bit 0→1`). Accepted.
- Never flash bootloader partitions (xbl/abl/aop/tz). We only touch `boot` + `vbmeta`. Download mode stays as the ultimate backstop.

## Steps
1. **To download mode:** `adb reboot download` (device is connected).
2. **Unlock (on device):** at the blue warning screen → **long-press Vol-Up** → Device Unlock Mode → **Vol-Up = Unlock**. Device wipes + reboots.
3. **Let VaultKeeper register:** allow it to boot to the OOBE/setup screen **once** (no account/wifi needed), then **power off** (hold Power → Power off). Confirms the unlock "took" (else it can silently re-lock).
4. **Re-enter download mode:** device off → hold **Vol-Up + Vol-Down together**, then plug USB → blue screen. (Verify `KG State: Checking/Normal`, and it should now say unlocked.)
5. **Flash (host):**
   ```bash
   cd root-build
   odin4 -l                                    # confirm device path
   odin4 -a kernelsu_boot.tar -u vbmeta_disabled.tar
   ```
   No `--reboot` → it won't auto-reboot. **← Knox trips here.**
6. **Boot to system:** unplug/hold **Vol-Down + Power** to exit download → boots to rooted One UI 7 (first boot slow; verity is off so no bootloop).
7. **Root shell:** install KernelSU Manager APK (`adb install` tiann KernelSU v1.0.5), open once, grant root to shell.
8. **dd backup (the real safety net):**
   ```bash
   adb shell su -c 'for p in boot dtbo super vbmeta vbmeta_system modem ...; do \
     dd if=/dev/block/by-name/$p of=/sdcard/bk_$p.img; done'   # then adb pull
   ```
   (Full partition list from device-facts/partitions-by-name.txt.)

## Recovery if a flash goes wrong
- Won't boot → download mode → `odin4 -a stock_boot.tar` (stock kernel back).
- Worse → get full stock firmware from a mirror (the Chrome download; or re-slice) → `odin4 -b BL -a AP -s CSC`.
- Download mode always available (we never touch the bootloader partitions).
