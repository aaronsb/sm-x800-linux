# Volume Up press tests and working-state dumps, 2026-09-19

Kernel 7.2-r3 on pmOS, tablet 192.168.2.123, GitHub issue #18. The pm8350 GPIO 6
interrupt fires on every press, but on some boots the pad level never leaves
high and gpio-keys emits nothing. The story and the tables are in the issue;
this directory holds the scripts and captures from the night's last three
boots (00:13 hard reset, 00:29 warm reboot, both working). Timestamps in the
logs are the tablet's clock, UTC.

The trap that has watched for the dead state since that night lives in
`tools/volup-trap/`.

## Samplers and their logs

| File | What it did |
|---|---|
| `ev5.py`, `ev5.log` | Read `/dev/input/event5` (gpio-keys) for 600 s and log every key event. The log shows KEY_VOLUMEUP (code 115) 1/0 pairs for each press at 9 and 15 min into the 00:13 boot. |
| `ev5_long.py`, `ev5_long.log` | Same, 2400 s, on the 00:29 boot. Presses at 1 min. |
| `fastsample.py`, `fastsample.log` | Poll STATUS1 (0x8d08), INT_RT_STS (0x8d10) and INT_LATCHED_STS (0x8d18) of the GPIO 6 peripheral by offset through `/sys/kernel/debug/regmap/0-01/registers`, about 14 k triplets per second for 240 s, and log every change. Each press shows as a clean 1 s low with the latch set at both edges. |
| `fastsample_long.py`, `fastsample_long.log` | Same, 2400 s, 00:29 boot. |

`ev5.py` and `fastsample.py` were run side by side; the same second in both
logs is the same press.

## Register writers

| File | What it did |
|---|---|
| `spmiw.py` | Userspace SPMI byte write to the 0x8dxx peripheral through the arbiter v7 RW channel of APID 434 (WDATA0 at +0x10, CMD at +0x00, status at +0x08). It does not work: `struct.pack_into` on musl issues two stores and the arbiter drops the command. Kept as the record of the channel layout; the writes in the issue were done with `devmem2` on the same addresses. |
| `tlmmout.sh` | `tlmmout.sh PIN 0|1` sets bit 1 (output value) of a TLMM pin's GPIO_IN_OUT register through `devmem2`. Used to hold the 14 pins stock drives low. |
| `dpmswatch.sh`, `dpms.log` | Log the panel's dpms and enabled state, the backlight and the GPIO_IN_OUT words of TLMM 0 and 34 every 2 s, on change. The one line in the log is the whole run: the panel never blanked, which retired the panel-off trigger idea. |

## Working-state dumps, 00:29 boot

Taken at 00:29:14 to 00:29:16 with the key working. They are the baseline a
trap capture is diffed against.

| File | Source |
|---|---|
| `gpio-working.txt` | `/sys/kernel/debug/gpio`, all chips |
| `pmic-working-0-00.txt`, `-0-01.txt`, `-0-02.txt` | `/sys/kernel/debug/regmap/0-0{0,1,2}/registers`: pmk8350 (SID 0), pm8350 (SID 1), pm8350c (SID 2). `XX` marks peripherals another EE owns; readable ones are EE0's. |
| `regulators-working.txt` | `name=state` for every `/sys/class/regulator/regulator.*` |

`volup-trap.py` writes its captures in the same formats, so `diff` against
these files is direct.
