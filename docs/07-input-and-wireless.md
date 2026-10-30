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

BT comes up as `hci0` with `wcnhpbtfw21.tlv`/`wcnhpnv21.bin` loading on 7.2
(`hpbtfw21.tlv`/`hpnv21.bin` on 6.13). The controller used to stop there,
unconfigured: the DT `bluetooth` node has no `local-bd-address` and the
bootloader supplies none, so `btmgmt info` listed no controller and
bluetoothd saw "No default controller available". The device package now
ships `gts8pwifi-bt-addr`, a oneshot pulled in by udev when `hci0` appears;
it mounts the `efs` partition read-only, reads the first address from
`bluetooth/bt_addr` and sets it with `btmgmt public-addr`, falling back to a
machine-id-derived locally administered address if efs is unusable. Scanning
finds devices; pairing is stock bluez userspace and still to be exercised.

### Local RX corrections

The kernel package carries two temporary patches for the pinned 7.2 base:

- `ath11k-rx-cleanup-locking.patch` backports Nicolas Escande's upstream
  [`c7555d47b1d0`](https://git.kernel.org/linus/c7555d47b1d051e0406474349deccf74b491ae01).
  Move expired entries to a private list before releasing the lock, so another
  caller cannot invalidate the iterator. Drop it when the base includes that commit.
- `ath11k-rx-buffer-alignment.patch` carries Mark Ruvald Pedersen's
  [alignment correction](https://lore.kernel.org/ath11k/20260719215817.2468580-2-wabsie@gmail.com/).
  `skb_pull()` cannot move an empty skb; `skb_reserve()` uses the allocated
  headroom to align both RX paths. Drop it when that correction reaches the base.

### Temporary firmware RX cache correction

`tools/ath11k-rx-cache-clean.py` provides an **experimental, opt-in** correction
for `WLAN.HSP.1.1-03125-QCAHSPSWPL_V1_V2_SILICONZ_LITE-3.6510.41`.
RX refill clears attention words at descriptor offsets 0x50–0x5c, but cleans
only 12 bytes from descriptor minus 8 before handing the buffer to hardware.
Extending that range to 104 bytes covers all cleared words, preventing later
dirty writeback from overwriting hardware-updated status.

The tool accepts only the exact original SHA-256, checks the instruction packet
and unsigned ELF integrity table, and changes one immediate plus its segment
checksum. It neither installs a driver nor changes firmware authentication.
No firmware images are distributed in this repository. This workaround does
not establish a fix for every cause of `msdu_done` or a whole-system freeze.

Run on the tablet with Python 3 installed, from this repository. For Alpine's
compressed firmware, first decompress a copy with `zstd -d -c` and use that
uncompressed file as the first argument. The original stays untouched:

```sh
sudo mkdir -p /lib/firmware/updates/ath11k/WCN6855/hw2.1
sudo python3 tools/ath11k-rx-cache-clean.py \
  /lib/firmware/ath11k/WCN6855/hw2.1/amss.bin \
  /lib/firmware/updates/ath11k/WCN6855/hw2.1/amss.bin
```

The output SHA-256 must be
`2f5fc9b391ec02dbced58a8d93d3e455213b74b8adf2d0c3aac28e956604fd66`.
The output is published atomically and an existing override is never replaced.
The kernel's `updates` search directory takes precedence over the distribution
image on the next boot. A custom `firmware_class.path` takes precedence over
`updates`; check for an existing override there first. This path targets the
WCN6855 hw2.1 firmware used by this port. Board files and other firmware remain
provided by `linux-firmware-ath11k`.

To roll back, remove only the generated `updates/ath11k/WCN6855/hw2.1/amss.bin`
and reboot. Remove that override **before updating `linux-firmware-ath11k`**
so it cannot mask a newer vendor image. Retire the tool when the vendor firmware
incorporates the equivalent cache-range correction; never relax its build guard
to patch a different release.

## Open threads

- `reboot-mode download` (PON `mode-download = 0x15`, wired in the DTS) is
  ignored by ABL. Leading theory: the PON spare bits only survive a **warm**
  reset and downstream forces warm-reset mode before rebooting with a reason
  set; mainline resets cold. Needs a qcom-pon investigation. Until then:
  `sudo shutdown now` at the keyboard, then the volume-keys+cable dance.
- Volume-up is still dead pending the spmi-gpio off-by-one fix (cell 5).
- Wacom EMR pen digitizer: separate chip, separate bus, unported.
