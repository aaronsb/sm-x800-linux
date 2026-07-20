# 07 — Input and wireless: touch, keyboard, WiFi, BT

One session took the port from "output-only console reachable over a USB dongle"
to "log in on the real keyboard, ssh over WiFi." This documents how each
subsystem was brought up, the facts a future porter needs, and what was ruled
out along the way. Per-change detail lives in the commit messages
(`git log 90ca518..`); this is the map.

## Touchscreen — STM FTS1BA90A (`fts1ba90a.c`)

**Why a custom driver:** mainline `stmfts` speaks an 8-byte-event FingerTip
protocol (opcodes 0x85/0x86, sense-on 0x92). The FTS1BA90A uses **16-byte
events** read with 0x60 (one) / 0x61 (all remaining) and sense control via
0xA0 — same silicon family, incompatible firmware ABI. `stmfts` probes `-110`.

**The port** (~530 lines, staged into `drivers/input/touchscreen/` by the
kernel APKBUILD, `obj-y`, no Kconfig) is a strip-down of Samsung's downstream
`fts_ts` driver with the `sec_input` factory layer removed. Init mirrors
downstream `fts_init` exactly: system reset (`FA 20 00 00 24 81`), CRC status
check, ready-event poll, chip-ID verify (0x39/0x36), touch-function 0x30,
force-cal 0x13, FIFO clear 0x62, scan-start `A0 00 01`. Commands with side
effects confirm via an echo event (`0x43 0x01` + echoed bytes). No firmware
download path — the IC's flash is already correct.

**Orientation was measured, not guessed:** with swap-only, a tap diagonal
produced anti-correlated coordinates with the visual top edge at the raw-X
maximum. The kernel helper applies inversion **before** the axis swap, so the
vertical flip is expressed as `touchscreen-inverted-x` (raw portrait axis) —
naive reading of the same data says inverted-y and is wrong.

## Book Cover Keyboard — pogo STM32 (`stm32-pogo.c`)

**The diagnosis that mattered** (see `tools/README.md` for the 14 ruled-out
hypotheses): the keyboard MCU is healthy and its firmware byte-identical to
stock; it cycles a disconnect state machine at ~5 Hz because the host never
completes a handshake. 12,158 userspace probes of 0x2a got zero ACKs because
**the MCU only serves its I2C address as part of an interrupt-driven
handshake** — polling can never see it.

**The handshake** (now in `stm32-pogo.c`, ported from 11.6k lines of
downstream into one file):

1. conn (tlmm 59, driven by the keyboard) goes high on dock.
2. Host enables the VDDO rail (tlmm 70 gpio regulator), waits 50 ms, enables
   the ATTN irq (tlmm 71, level low).
3. MCU pulls ATTN low; host answers with a 3-byte header write
   `{len_lo, len_hi, ep}` at 0x2a and reads back a 3-byte header + payload.
4. The first exchange is empty; its ep byte carries the keyboard model. Host
   reads the MCU version and pushes it into APP mode. From then on ATTN
   signals events: ep 2 = touchpad, 3 = keypad, 4 = hall, 5 = accessory.

Key events are u16 `{press:1, col:5, row:3}` into an 8×24 matrix; both
models' keymaps were extracted from the stock DTB (they differ in two keys)
and are embedded as tables. The caps-lock LED rides in the header-write ep
byte (1 = off, 2 = on). Touchpad presence is a **u16** version check (absent
pads report major 0xff, which is bytes `00 ff` — byte-wise comparison
misreads it; that bug shipped in r23 and produced a phantom touchpad). The
pad, when present, is a plain 3-slot MT clickpad; Samsung's in-driver
click-zone heuristics were deliberately left to libinput.

Not ported: firmware update (MCU flash verified byte-identical to stock),
sysfs factory interface, notifier chain, bus voting. nrst (tlmm 97) is held
high and pulsed to recover a wedged MCU on i2c failure; swclk (gpio 99) is
left unclaimed for the ROM-bootloader dump tooling.

## WiFi + BT — WCN6855 ("QCA6490")

**Identification:** stock's `cnss-qca6490` is the WCN6855 family. The DTS is
a near-copy of `sm8450-hdk.dts` and legitimately so — every stock enable GPIO
(wlan 80, bt 81, sw-ctrl 82, xo-clk 204), every supply rail (resolved from
stock phandles: s10b/s11b/s12b/s1c/pmr735a_s2), and even the BT serial engine
(stock `hsuart0` @ 0x894000 = mainline `uart20`, pins 76–79) match the QC
reference design.

**What it took beyond the HDK copy:**

- Rails declared: smps10/11/12 (pm8350), smps1 (pm8350c), a new `pmr735a`
  regulators node (s1e/s2e). PCIe0 + QMP PHY enabled; ath11k `wifi@0` child
  consumes the `wcn6855-pmu` LDO outputs (power sequencing via
  `pwrseq-qcom-wcn` + PCI pwrctl — all already `=m` in the config).
- **Serial aliases are load-bearing:** `qcom_geni_serial` derives its tty
  line from `serialN` aliases and fails probe with `Invalid line -19`
  without one. This had silently broken uart7 since bring-up (earlycon
  bypasses the tty layer, hiding it) and kept uart20's `wcn6855-bt` serdev
  child from ever binding — and the failed uart20 probe held four
  interconnect providers' `sync_state()` hostage (third sighting of the
  deferred-probe-blocks-sync_state trap).
- Firmware from `linux-firmware-ath11k` + `linux-firmware-qca` (the kernel
  has `FW_LOADER_COMPRESS_ZSTD` for Alpine's `.zst` blobs). The upstream
  `board-2.bin` has an **exact entry** for this board's identity
  (`17cb:1103`, subsys `17cb:0108`, chip 2, board-id 255) and works.
- Persistence: NetworkManager (the pmOS default) owns wlan0; a saved profile
  autoconnects at boot. Do not hand-run wpa_supplicant — it steals the
  interface from NM.

**Ruled out / field notes:**

- Samsung's downstream `bdwlan.elf` board files **crash** mainline ath11k
  firmware (`MHI_CB_EE_RDDM`) — downstream BDFs pair with downstream cnss
  firmware only. Do not retry.
- There is no physical antenna switch on this tablet (owner-confirmed);
  stock's `wlan-ant-switch` supply is a QC reference DT leftover.
- One bad first association was seen on r26 (ARP INCOMPLETE, rate stuck at
  1 Mbit); an ath11k module reload with the same board file fixed it and it
  has not recurred since the aliases fix. Watch, don't chase.

BT comes up as `hci0` with `hpbtfw21.tlv`/`hpnv21.bin` loading; pairing is
stock bluez userspace and untested as of this doc.

## Open threads

- `reboot-mode download` (PON `mode-download = 0x15`, wired in the DTS) is
  ignored by ABL. Leading theory: the PON spare bits only survive a **warm**
  reset and downstream forces warm-reset mode before rebooting with a reason
  set; mainline resets cold. Needs a qcom-pon investigation. Until then:
  `sudo shutdown now` at the keyboard, then the volume-keys+cable dance.
- Volume-up is still dead pending the spmi-gpio off-by-one fix (cell 5).
- Wacom EMR pen digitizer: separate chip, separate bus, unported.
