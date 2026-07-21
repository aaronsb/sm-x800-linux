# tools/

On-device bring-up helpers. Everything here is **read-only** with respect to device
flash — no tool in this directory erases or writes an MCU.

Run them over ssh:

```sh
scp tools/<script> user@<ip>:/tmp/
ssh user@<ip> 'echo <pw> | sudo -S sh /tmp/<script>'
```

## Current tools

| Tool | Purpose |
|---|---|
| `stm32boot.py` | STM32 I2C ROM-bootloader client (ST AN4221). `getid`/`getver`/`get`/`read`/`readraw`/`go`. One command per invocation, by design — see the state-hygiene note below. |
| `pogo-stm32-info.sh` | Pulse the pogo MCU into ROM bootloader and interrogate it. |
| `pogo-stm32-dump.sh` | Dump the MCU's application flash, 256 bytes per pulse. |
| `pogo-status.sh` | Quick pogo state readout: dock, conn edges, gpio levels, rail, pin mux, 0x2a. |

## After any userdata/rootfs flash

Reflashing userdata wipes the on-device state this port leans on. The image stays
minimal by design (Alpine composes with metapackages, not baked images) — assembly
is one command:

```sh
sudo gts8pwifi-setup            # device toolkit metapackage + GPU fw extraction
sudo gts8pwifi-setup plasma     # same, plus Plasma Desktop 6 (KWin Wayland)
```

The toolkit lives in the `device-samsung-gts8pwifi-tools` metapackage (i2c-tools,
libgpiod, evtest, iw, wpa_supplicant, tcpdump, bluez, mesa-dri-gallium, kmscube,
btop, strace). The load-bearing firmware packages (linux-firmware-ath11k/-qca/
-qcom) and reboot-mode are hard `depends` of the device package itself, so a
fresh image always has them. The NetworkManager WiFi profile is also lost with
userdata — re-add with `nmcli dev wifi connect <ssid> password <pw>` or the
dongle comes back out.

The GPU additionally needs the Samsung-signed zap shader, which no repo and no
package may ship (cartridge-dump model: we distribute the extractor, the user
dumps firmware from their own device). One command, device pkg r14+:

```sh
sudo gts8pwifi-fw-extract   # mounts apnhlos ro, stages the zap, reruns mkinitfs
```

It must end up in the initramfs (a7xx loads firmware at bind time, before the
rootfs mounts) — the extractor's mkinitfs run handles that via
60-gts8pwifi-gpu-fw.files.

(Local copies of the zap splits also live in root-build/stock-extract/. The BUILD
chroot side is automated: `make boot` depends on `make stage-fw`, which copies the
splits into the chroot, regenerates its initramfs, and HARD-FAILS if the zap did
not land — no more silently GPU-less boot images.)

Also note `sudo sh -c "..."` does not inherit a login PATH, so `i2cdetect` and friends
may report "not found" even when installed. Use a login shell or an absolute path.

## Device-specific gotchas

These cost real time; they are not generic Linux knowledge.

- **Never run two pmbootstrap operations concurrently** (e.g. a device-pkg
  `pmb checksum`/`pmb build` while a background `make kernel` runs). They
  share the aports work tree and interleaved runs cross-write APKBUILDs —
  we got the kernel APKBUILD's content written into the device package (and
  a mangled double checksum block) exactly this way. Recovery: `rm -rf` both
  aports dirs and let `make kernel` re-sync from the overlay. Also beware
  `... 2>&1 | tail` masking a failed build's exit code — verify the apk file
  exists, not the pipe status.
- **Do not run bulk raw reads of UFS block devices on the running device**
  (e.g. `strings /dev/disk/by-partlabel/super` — 10.7 GB). The one time we
  did, the system died minutes later: touch i2c writes started failing,
  then the panel, then the network, then hard-off — with the persistent
  systemd journal's last entry being that scan starting. Battery was at
  98%/4.25 V, so not a brown-out. Mechanism unknown (I/O wedge? thermal?);
  every stock partition of interest exists locally in
  device-facts/partitions-backup/ (11 GB super.img included) — search
  there. Note super's members are EROFS (compressed): raw `grep`/`strings`
  over the image finds nothing; `lpunpack` + loop-mount, then search files.
- **The zap shader lives in the `apnhlos` partition** (`/image/a730_zap.mdt`
  + `.b00-.b02`), not in vendor/ or modem/. Mount `/dev/disk/by-partlabel/apnhlos`
  (vfat, ro) to get at it. Copies staged at
  /lib/firmware/qcom/sm8450/gts8pwifi/ on-device and in root-build/stock-extract/.
- **ath11k bulk-RX wedge**: sustained high-rate downloads stall to ~KB/s with
  `ath11k_pci ... msdu_done bit in attention is not set` in dmesg — a known
  WCN6855 RX-ring bug. Small traffic (ssh) keeps working, which disguises it
  as a mirror/network problem. Recovery: `modprobe -r ath11k_pci && modprobe
  ath11k_pci` (NM re-associates itself). For big installs use a
  stall-detect/module-cycle loop. Proper fix: hunt the upstream ath11k patch
  for this and carry it in the kernel package.
- **libgpiod on the device is v2.** `gpiofind` does not exist. Use `gpioinfo | grep pogo`
  and `gpioget -c gpiochip3 <line>`.
- **gpiochip3 = `f100000.pinctrl` = TLMM** (211 lines). gpiochip0/1/2 are
  pm8350 / pm8350c / pmk8350.
- **A backgrounded `gpioset` must have its stdio detached** (`>/dev/null 2>&1 </dev/null &`)
  or an ssh session will hang forever waiting on the fd.
- **`gpioset` holds a line only while its process lives.** Drive multi-pin timed sequences
  from ONE `gpioset --interactive` fed by a fifo. Killing and restarting between
  transitions lets a line float at exactly the wrong moment.
- **A stale `gpioset` silently invalidates the next experiment** by holding a line (EBUSY).
  Always check for `Resource busy` before trusting a result.
- **`i2cdetect -y N` lies on geni.** No SMBus Quick Write, so it *skips* most addresses
  including 0x2a. Always use `-r`.
- **`evtest --query` point-samples.** Against a line toggling at ~5 Hz it returns a
  random answer. Trust edge **counts**, not point samples. This produced every
  inconsistent dock reading in the pogo investigation.
- **STM32 bootloader state hygiene.** The bootloader wedges after *any* stray or
  malformed traffic and then times out on everything until the next nRST/BOOT0 pulse.
  A bare read with no command pending returns 0x1F and poisons it. **Never pre-probe
  "is it there?"** — that check is what breaks the thing it is checking. Give every
  command its own fresh pulse and let its `0x79` ACK be the proof.
- **ACK = 0x79, NACK = 0x1F.** (Easy to get backwards; we did.)
- **A deferred probe can break something far away.** `i2c8` could not get a GPI DMA
  channel, sat in deferred probe, and blocked `sync_state()` on four interconnect
  providers — which starved the NoC votes storage depends on and made the initramfs fail
  to find subpartitions. The error named storage; the cause was a touchscreen bus. Check
  `/sys/kernel/debug/devices_deferred` when something inexplicable is slow or missing.

## Pogo keyboard: what is already ruled out

The Book Cover Keyboard investigation is complete as a *diagnosis*. Do not re-run these —
each was tested on hardware and the tool deleted afterwards. Full evidence is in the git
history (`git log --grep pogo`).

| Hypothesis | Result |
|---|---|
| Keyboard not attached / not seated | Ruled out — dock state tracked, MCU answers when attached |
| Pin mux wrong | Ruled out — `pinmux-pins` shows gpio68/69 = `function qup18`, claimed by `88c000.i2c` |
| Bus dead | Ruled out — probes return ENXIO (a real NACK), no geni errors logged |
| conn-detect floating | Ruled out — 51 edges under **both** pull-up and pull-down bias |
| MCU held in reset | Ruled out — nRST pulsed and held high; no change |
| MCU needs a power cycle | Ruled out — full rail-off/reset/rail-on sequence while docked |
| We cause the oscillation | Ruled out — holding nrst=1 + swclk=0 left the rate identical (51→51→52) |
| Brownout / missing second supply | Ruled out — all three stock fixed regulators accounted for |
| MCU is in the tablet | Ruled out — detached, nothing ACKs anywhere; conn edges 52 → 1 |
| Blank or corrupt firmware | Ruled out — flash is **byte-identical** to stock `stm32_gts8p.bin` |
| Bad entry into the app | Ruled out — bootloader `GO 0x08000000` ACKs, app still silent |
| Lid / typing position | Ruled out — no change in typing position |
| Host must drive CON low ("1Wire") | Ruled out — held low 2s and 7s, pulsed 100ms and 3×500ms; silent |
| Wrong bootloader address | Ruled out — 0x51 is hardcoded in the downstream driver |
| MAX77816 keyboard boost rail | Ruled out — on this device it is `max77816,display_boost` |

**Conclusion:** the MCU is healthy, its firmware is correct, and the fault is host-side.
The keyboard runs a connection state machine (`Disconnected_sequence_proc`) and cycles at
~5 Hz because the host never completes the handshake — userspace cannot bootstrap 0x2a
because the keyboard only exposes it after reaching the connected state (12,158 probes in
20s, zero ACKs).

**PORTED (kernel r23):** the handshake now lives in the mainline `stm32-pogo.c` driver in
the kernel package (see the file's header comment for the protocol). If the keyboard is
dead, start from `dmesg | grep pogo` — the driver logs conn edges, the handshake, and the
model/version it reads — not from re-probing the bus.

**DEAD LEAD — do not chase.** The firmware string `SLPI I2C CLK Rlease!!!` looked like
evidence that the Sensor Low Power Island was the keyboard's real conversation partner.
It is not. That string sits next to `STM32G0 I2C CLK Rlease!!!` in the same blob — the
pair is a two-peripheral bus-recovery log, and "SLPI" is the MCU's own legacy name for
its host-facing I2C port, inherited from the Tab S7. `grep -rni slpi` across all 13 files
in `kernel-src/drivers/input/sec_input/stm32/` returns zero.

**Actual open lead:** `"CON Low -> 1Wire 3.3V defance code!!"` in the same firmware — a
1-Wire detect path on the connect line. Note that simply driving CON low from the host
was already tested and did nothing (held 2s and 7s, pulsed 100ms and 3x500ms), so if
there is something here it needs real 1-Wire signalling, not a level change.
