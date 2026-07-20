# Device Facts — SM-X800 (gts8pwifi), confirmed from hardware

Pulled via `adb getprop` / sysfs on 2026-07-18 from the actual unit (serial redacted). Raw: `getprop-full.txt`, `partitions-by-name.txt`, `slot-and-sizes.txt`.

## Identity
| Field | Value |
|---|---|
| Model | SM-X800 |
| Device / product | `gts8pwifi` / `gts8pwifixx` |
| SoC | Qualcomm **SM8450** (`taro`), QTI |
| GPU | Adreno 730 (`ro.hardware.egl=adreno`, vulkan=adreno) |
| Android | 15 (SDK 35) |
| Build | `AP3A.240905.015.A2.X800XXU9DYDC` |
| Bootloader | **`X800XXU9DYDC`** |
| Security patch | 2025-04-01 |
| Kernel | **`5.10.226-android12-9`** GKI, built `abX800XXU9DYDC` Tue Apr 15 2025 |
| Carrier | wifi-only |

## Unlock / security state (all stock, cleared to unlock)
| Field | Value | Meaning |
|---|---|---|
| **`sys.oem_unlock_allowed`** | **`1`** | ✅ **OEM unlock permitted on this unit** |
| `ro.boot.flash.locked` | `1` | currently locked (stock) |
| `ro.boot.vbmeta.device_state` | `locked` | AVB locked (stock) |
| `ro.boot.verifiedbootstate` | `green` | untampered (stock) |
| `ro.boot.warranty_bit` | `0` | Knox intact (not yet tripped) |
| `ro.boot.veritymode` | `enforcing` | dm-verity on |

→ Firmware is One UI 7 / April 2025, **not** One UI 8. Unlock path open. **Do not let it OTA.**

## Storage / partitions (A-only, no A/B slots — `slot_suffix` empty)
| Partition | Block | Size | Role |
|---|---|---|---|
| `boot` | sda25 | 96 MB | **pmOS flash target** (kernel + initramfs) |
| `dtbo` | sda34 | 8 MB | device-tree overlays |
| `super` | sda28 | ~10.4 GB | dynamic (system/vendor/product/odm/…) |
| `recovery` | sda26 | — | stock recovery / TWRP target |
| `splash` | sde12 | — | boot splash image region (relevant to simple-framebuffer) |
| `vbmeta*` | (in raw map) | — | AVB metadata |
| `up`/`userdata` | (in raw map) | — | userdata |

Full 98-entry map in `partitions-by-name.txt`. Qualcomm boot chain lives on `sde*`/`sda*` (aop, abl, xbl, hyp, tz/keymaster, cpucp, devcfg…). Flashing = Samsung **download mode, no fastboot**.

## Confirmed components (match the q4q proxy predictions)
| Block | Evidence | Target driver |
|---|---|---|
| WiFi/BT | BT SoC `hastings`, `pcie-wifi`, `swlan0` dual-concurrent | **ath11k** (QCA6490/WCN6855) + board-2.bin BDF |
| Touchscreen | `/sys/class/sec/tsp` | STM `stm_ts` (needs port) |
| Stylus | `/sys/class/sec/sec_epen` | Wacom EMR (needs port) |
| USB-PD | `/sys/class/sec/{muic,ccic,typec_manager}` | pmic-glink |
| Thermals | `sec-ap-thermistor`, `sec-wf-thermistor` | — |
| Cover | `/sys/class/sec/hall_ic` | hall-switch |
| Display | panel DDIC not readable as shell user | resolve from OSRC `gts8x` DTS (Samsung S6E3-class) |

## Immediate implications for Phase 1
- **Stock firmware to archive for restore = `X800XXU9DYDC`** (match CSC; source: samfw / Frija).
- Flash tooling: install **`odin4`** or **Thor** (not Heimdall).
- pmOS `deviceinfo`: `flash_method=heimdall-bootimg`, no A/B, `boot` partition target.
