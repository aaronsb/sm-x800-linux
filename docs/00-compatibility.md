# 00: Compatibility, which SM-X800 units can still take this port

Verified on 2026-09-21 against the SM-X800 firmware listing at
[samfrew.com](https://samfrew.com/firmware/model/SM-X800/upload/Desc/0/10)
(pages 1 to 21 of 62, every build from October 2024 to the newest upload).

The unlock and root path in `docs/01-unlock-root-runbook.md` needs a tablet
whose bootloader will still accept a One UI 7 firmware. Samsung gates that
with the binary counter fused into the bootloader, not with the One UI
version. Any SM-X800 on binary 9 or lower qualifies, and that includes the
first three months of One UI 8. Any SM-X800 on binary A or later does not, and
no known exploit reopens it. A tablet that has taken its normal updates since
February 2026 is on binary A or B.

## Read your binary

Settings > About tablet > Software information > Build number. The last
dot-separated segment is the firmware build string, for example
`X800XXU9DYDC`. The binary is the fifth character from the end:

```
X800XXU9DYDC
       ^ binary 9
X800XXSAEZB6
       ^ binary A
```

The bootloader refuses any image whose binary is lower than the fused one. The
download-mode screen reports the refusal as `SW REV. CHECK FAIL`, with the
fused and offered values, and Odin reports `FAIL!`. The binary only ever goes
up: flashing a binary-A firmware onto a binary-9 tablet fuses A permanently.

## Firmware history

All rows come from the samfrew listing. Dates are the listing's upload dates.
Android version is what the listing shows; the One UI column maps Android 14
to One UI 6.1, Android 15 to One UI 7 and Android 16 to One UI 8. The build
strings are the international `XX` builds; the China (`ZC`) and Japan (`OP`)
builds of the same date carry the same binary character.

| Build | Listed | Android | One UI | Binary | Note |
|---|---|---|---|---|---|
| X800XXS8CXJ7 | 2024-10-14 | 14 | 6.1 | 8 | last binary 8 |
| X800XXU9CXK9 | 2024-11-13 | 14 | 6.1 | 9 | first binary 9 |
| X800XXS9CYB1 | 2025-02-03 | 14 | 6.1 | 9 | |
| X800XXU9DYDC | 2025-04-15 | 15 | 7 | 9 | this port was developed on it |
| X800XXS9DYF4 | 2025-06-30 | 15 | 7 | 9 | |
| X800XXS9DYI1 | 2025-09-15 | 15 | 7 | 9 | last One UI 7 |
| X800XXU9EYJ4 | 2025-10-16 | 16 | 8 | 9 | first One UI 8 |
| X800XXS9EYK1 | 2025-11-26 | 16 | 8 | 9 | |
| X800XXS9EZA3 | 2026-01-14 | 16 | 8 | 9 | last binary 9 |
| X800XXSAEZB6 | 2026-02-13 | 16 | 8 | A | door closes |
| X800XXSBEZE1 | 2026-05-20 | 16 | 8 | B | |
| X800XXSBEZH3 | 2026-08-14 | 16 | 8 | B | newest upload on 2026-09-21 |

One UI 8 arriving at binary 9 is also reported by
[Sammy Fans, 2025-10-30](https://www.sammyfans.com/2025/10/30/samsung-galaxy-tab-s8-starts-receiving-one-ui-8-update-globally/),
which names the EYJ4 build for the Tab S8 series rollout.

## Decision rule

**Binary 9 or lower: open.** Odin-flash a complete binary-9 One UI 7 firmware
(BL, AP, CP, CSC), for example X800XXU9DYDC or X800XXS9DYI1. Samsung signed
it, so the flash needs no unlock and does not trip Knox. It wipes the tablet.
A binary-8 tablet fuses 9 in the process. Then enable Developer options >
OEM unlocking and follow `docs/01-unlock-root-runbook.md` from step 1. On a
freshly flashed tablet the OEM unlocking toggle can stay hidden until the
tablet has completed one boot with network; that timing is from Samsung
convention, not from a test on this hardware.

**Binary A or higher: closed.** The One UI 7 downgrade fails the software
revision check, and none of the known routes around it apply:

- The March 2026 Qualcomm GBL exploit chain targets a bootloader stage that
  loads an unsigned UEFI app from an `efisp` partition on Android 16 launch
  devices. Samsung's S-Boot chain is unaffected, and this tablet has no
  `efisp` partition (`device-facts/partitions-by-name.txt`). Source:
  [Android Authority](https://www.androidauthority.com/qualcomm-snapdragon-8-elite-gbl-exploit-bootloader-unlock-3648651/).
- Emergency download mode needs a Firehose programmer signed for this
  device's root of trust, and none is public. The discovery notes record EDL
  as not viable: `docs/discovery-notes/04-mainline-prep.md`.

Candidates for the open case in September 2026 are tablets with automatic
updates switched off, sealed shelf stock, and used units that were never
updated past January 2026.

## If you are on binary 9 today

Switch off automatic updates before anything else: Settings > Software
update > Auto download over Wi-Fi, off. Decline any update prompt. One accepted
update to EZB6 or later ends the option.

## What this port was developed on

X800XXU9DYDC, One UI 7, binary 9. The root artifacts in `root-build/` (the
KernelSU boot image and the stock boot insurance) were sliced from that
firmware, so a tablet downgraded to DYDC matches the runbook exactly. Other
binary-9 One UI 7 builds work for the unlock but need their own stock boot
image for the KernelSU repack.
