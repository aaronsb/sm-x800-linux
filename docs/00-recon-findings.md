# Phase 0 — Recon & Feasibility Findings

**Target:** Samsung Galaxy Tab S8+ Wi-Fi, **SM-X800**, codename **gts8p**
**SoC:** Qualcomm **SM8450** (Snapdragon 8 Gen 1), Adreno 730 GPU
**Goal:** Mainline Linux / postmarketOS — "boots to usable Linux, with a path to daily driver"
**Current device state:** unrooted, One UI 7.0 / Android 15, Knox 3.11 (API 38), SE-for-Android enforcing `SEPF_SM-X800_12_0001`, security patch 2025-04-01. WiFi deliberately blocked at the router to prevent OTA updates.

_Research date: 2026-07-18._

---

## Verdict: GO — but the unlock is time-critical

Unlock is feasible and permitted **on the current firmware**. A finished Linux port does **not** exist — this is a from-scratch board bring-up off proven SM8450 templates.

### ⏳ The cliff: unlock BEFORE One UI 8 (Android 16)
One UI 8 ships `androidboot.other.locked=1` in the bootloader, which **removes the OEM-unlock toggle entirely** — on international units, not just US carrier — with **no rollback** (anti-rollback index bumped; cannot Odin back to an unlockable build). If this tablet ever OTAs to One UI 8, the project is permanently dead.

**Mitigations (in force / to do):**
- [x] WiFi blocked at UniFi (anti-OTA) — keep it blocked.
- [ ] Also disable auto-download of updates in Settings before any controlled one-time connection.
- [ ] Unlock during a controlled connection with OTA/FOTA domains still blocked.

Primary sources: Android Authority 2025-07-27 (`androidauthority.com/samsung-bootloader-unlocking-disabled-one-ui-8-3581366`); SamMobile; bootloader-unlock wall-of-shame (`github.com/zenfyrdev/bootloader-unlock-wall-of-shame`, updated 2025-12-06). Note: One UI 7 is the last unlockable line; the "Feb-2025 patch blocks it" claim is low-trust SEO content that contradicts primary reporting.

---

## Unlock procedure (button-less tablet)

1. Settings → About → Software info → tap **Build number** ×7 → Developer options.
2. Developer options → enable **OEM unlocking** (requires internet handshake; must be done *before* download mode). **If greyed out → KG Prenormal state, see below.**
3. Power off. Enter **Download/Odin mode**: with tablet off, hold **Vol-Up + Vol-Down together**, then plug in USB-C (data cable) → hold to blue warning screen.
4. **Long-press Vol-Up** → Device Unlock Mode → **Vol-Up = Yes** to unlock. **This factory-resets the device.**
5. Re-setup, reconnect once, confirm Developer options shows **"Bootloader already unlocked"** (Vaultkeeper must register it or it can silently re-lock).

### KG / RMM "Prenormal" 7-day wait
After *any* factory reset, KG state → `Prenormal` for **168 hours**, during which the OEM-unlock toggle is greyed/hidden. Check via the `KG State:` / `RMM State:` field on the download-mode screen. Satisfy by: Samsung account signed in + online + wait 7 days; known workaround = advance system date ~7–10 days (hit-or-miss; Samsung RMM servers are flaky). **Implication: enable OEM-unlock BEFORE ever resetting; check the toggle's current state first.**

### Knox / ARB
- Unlock + its factory reset do **not** trip Knox or burn ARB.
- **First custom flash trips Knox efuse permanently** (Secure Folder / Samsung Pay / some DRM die forever) — accepted.
- Being on 2025-04 firmware is safe to unlock as-is (not a downgrade). ARB is forward-looking: don't let the *bootloader* reach One UI 8.

---

## Flashing tooling (Linux host = this Arch box)

- **Do NOT use stock Heimdall** — it doesn't send Odin protocol v4; broken on modern Samsung.
- **Use `odin4`** (Samsung's official Linux CLI) or **Thor** (`github.com/Samsung-Loki/Thor`).
- Host udev: Samsung rules, vendor `04e8`; may need `modprobe -r cdc_acm` before flashing.
- Samsung uses download mode, **no fastboot**. pmOS `deviceinfo`: `flash_method=heimdall-bootimg`.
- Already on host: `adb`, `fastboot`, `mkbootimg`, `avbtool`, `lz4`, `python3`. To install: `odin4`/`thor`.

---

## Prior art & reusable scaffolds

| Asset | What it gives us | Link |
|---|---|---|
| Samsung OSRC kernel source (gts8x, kernel 5.10) | Downstream DTS + panel/touch/PMIC/regulator config to port node-by-node; fast downstream-first boot | opensource.samsung.com → model `SM-X800`; community mirror `github.com/akm-04/Samsung_Kernel_sm8450_common_gts8x` |
| TWRP device tree (gts8p) | Partition map, boot-image geometry, working intermediate recovery | `github.com/afaneh92/android_device_samsung_gts8p` |
| `r0q` = Galaxy S22, **in mainline Linux** | 145-line SM8450 DTS skeleton: simple-framebuffer + UFS + USB2 — the day-1 boot template | `torvalds/linux` `arch/arm64/boot/dts/qcom/sm8450-samsung-r0q.dts` |
| `q4q` = Z Fold4, downstream DTB extracted | Closest Samsung-SM8450 component reference (panel/touch/wifi/audio parts) | `github.com/sm8450-mainline/fdt` |
| sm8450-mainline kernel + pmaports | Upstream SM8450 base + porting infra | `github.com/sm8450-mainline` |

**No existing:** pmOS wiki page, pmaports device package, or mainline `gts8p` DTS. All from scratch.

---

## Hardware bring-up scope (from q4q proxy + specs)

| Block | Component | Mainline status | Notes |
|---|---|---|---|
| SoC (clocks, regulators, RPMh, UART) | SM8450 + PM8350x | **Works** | since ~v5.17; r0q boots today |
| Storage | UFS 3.1 `1d84000.ufshc` | **Works** | DT nodes + regulators |
| USB2 peripheral | dwc3 + hsphy | **Works** | RNDIS for first-boot debug |
| USB3 / DP-alt / PD | QMP SS phy + pmic-glink | **Partial** | per-device PD/retimer work |
| GPU | Adreno 730 (a730) | **Works + firmware** | Freedreno/Turnip; needs `a730_sqe.fw`, GMU fw, **Samsung-signed zap shader** (extract from device) |
| WiFi/BT | QCA6490 (WCN6855-class) | **Works + firmware** | ath11k; needs per-device `board-2.bin` BDF from `/vendor`, BT rampatch/NVM |
| Charger/fuel gauge | Maxim MAX77705 | **Partial→Works** | mainlined 2025; direct-charge SM5451 + wireless CPS4038 downstream-only |
| Haptics | MAX77705 haptic | **Partial** | |
| Touchscreen | STMicro `stm_ts` (SPI) | **Needs driver** | no mainline FingerTipS driver; port from downstream |
| Stylus | Wacom EMR (S-Pen) | **Needs driver** | Samsung Wacom variant differs from `wacom_i2c` |
| Display panel | Samsung SDC `S6E3`-class DDIC, 12.4" 2800×1752 48–120 Hz | **Needs driver (hardest)** | day-1 = simple-framebuffer; native DSI/DPU panel driver is the wall |
| Audio | WCD938x + WSA883x (+ CS35L41) | **Needs integration** | codecs upstream; LPASS/q6 machine glue is the last/hardest part |
| Suspend/resume | SM8450 RPMh s2idle | **Partial** | enters, but idle-power/wake tuning needed for daily-driver battery |

### Bring-up order (easiest → hardest)
1. Author gts8p DTS → boot + UFS + USB2 + regulators → **serial/framebuffer console**
2. simple-framebuffer display (static, bootloader-lit)
3. GPU a730 (firmware + zap shader)
4. WiFi/BT ath11k (board-2.bin BDF)
5. Charging (MAX77705)
6. Touchscreen (STM `stm_ts` port)
7. S-Pen (Wacom)
8. Suspend/resume power tuning
9. Audio (LPASS/q6 machine)
10. **Native AMOLED panel driver** — hardest single driver; where daily-driver-grade lives or dies

---

## Recommended path

**Two-track, downstream-first** (standard pmOS practice):
1. **Unlock + safety net** — establish stock-firmware restore via odin4 *before* any experimental flash.
2. **Downstream-first boot** — pmOS on the OSRC 5.10 `gts8x` kernel → fast path to a shell (framebuffer + RNDIS `telnet 172.16.42.1`).
3. **Mainline track in parallel** — author `sm8450-samsung-gts8p.dts` off the r0q skeleton + q4q components; grow it block-by-block per the order above.

**Milestone = "usable Linux":** framebuffer console + WiFi + a Wayland DE over the bootloader-lit display. Achievable.
**Milestone = "daily driver":** gated on the native panel driver, audio, touch/stylus, suspend. Long haul, eyes open.
