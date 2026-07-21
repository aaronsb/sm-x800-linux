# S Pen — Wacom WEZ01 EMR digitizer (gts8pwifi)

Bring-up reference for the S Pen digitizer. Status: **chip proven alive on the
bus; no driver yet.** The DT wiring below is merged and flashed (r44); the driver
is the remaining work.

## Identity & bus

| | |
|---|---|
| Part | Wacom WEZ01 EMR digitizer (`compatible = "wacom,w90xx"`, MPU id `0x46`) |
| Bus | QUP **SE14** = `i2c@a98000` = mainline **`&i2c14`**, 400 kHz, pins gpio52/53 |
| Address | `0x56` |
| Firmware | `wez01_gts8p.bin` (harvested; `tools/fw-manifest.tsv`) — NOT needed to read the chip; it already runs its app firmware |
| Downstream driver | `kernel-src/drivers/input/wacom/` (10k lines, sec_input framework) |

Mapping was recovered from the resolved stock DTB (`device-facts/dt/stock-fdt.dtb`
→ `qupv3_se14_i2c: i2c@a98000` → `wacom@56`). SE14 shares the QUP1 wrapper with
the working touch bus (`&i2c8`), so the GPI-DMA deferred-probe cascade that
plagued i2c8 bring-up does not re-apply.

## Wiring (merged into sm8450-samsung-gts8pwifi.dts)

```
irq  -> &tlmm 51  (epen-int,  input, IRQ_TYPE_LEVEL_LOW)
fwe  -> &tlmm 54  (epen-fwe,  flash-enable, driver-owned)
pdct -> &tlmm 155 (epen-pdct, pen-detect / garage, input)
avdd -> wacom_avdd (regulator-fixed on &tlmm 167, active-high)
```

`wacom_avdd` is `regulator-always-on` **as a bring-up crutch** so the chip powers
up with no driver — drop that once the driver owns the rail (as stm32-pogo did
for `pogo_vddo`).

## Probe result (r44, on-device)

`i2cdetect -y -r <SE14 bus>` → **`0x56` ACKs.** The bus maps to `/dev/i2c-3`
(of_node `i2c@a98000`); the `/dev/i2c-N` index is assigned by probe order, so map
by of_node, not by "14". `&i2c14` probed clean — no `a98000`/storage entry in
`/sys/kernel/debug/devices_deferred` (only the pre-existing audio/LPASS stalls).
The FTS capacitive touchscreen does **not** see the EMR pen (0 bytes on event2
while drawing), as expected for a passive EMR stylus.

## Protocol (from the downstream driver)

**Query** — send `COM_QUERY` (`0x2A`), read back a buffer; the query block starts
where `query[0] == 0x0F` (EPEN_REG_HEADER). Big-endian pairs:

```
max_x        = query[1]<<8 | query[2]
max_y        = query[3]<<8 | query[4]
max_pressure = query[5]<<8 | query[6]
fw_ver       = query[7], query[8]
mpu_ver      = query[9]     # expect 0x46 (WEZ01) — a live sanity check
bl_ver       = query[10]
tilt_x/y     = query[11], query[12]
height       = query[13]
```

**Coordinate packet** — `COM_COORD_NUM = 16` bytes (read 17). `data[0]` is the
header; low nibble is the packet type (`NOTI_PACKET = 13`, else pen data):

```
prox   = data[0] & 0x10      # pen in range (hover)
side   = data[0] & 0x20      # side button
eraser = data[0] & 0x40      # tool = rubber, else pen
x        = data[1]<<8 | data[2]
y        = data[3]<<8 | data[4]
pressure = data[5]<<8 | data[6]
# tilt_x/tilt_y/height live in the later bytes — confirm exact offsets
# against a raw packet dump (see below); the AOP handler reuses data[6]
# for mode/wakeup, so the screen-on layout must be read from the main path.
```

Axis fixups (stock): landscape frame is `xy_switch` + one inverted axis; stock
`wacom,invert = <0 1 1>`. The panel is 2800×1752 landscape (same physical flip as
the touchscreen — see the fts axis note in the DTS).

Start/stop sampling: `COM_SAMPLERATE_START` (`0x31`) / `COM_SAMPLERATE_STOP`
(`0x30`); survey/scan modes at `0x2B`–`0x3B`. See `wacom_reg.h`.

## Port plan

Distill the downstream driver into a single mainline file
(`drivers/input/touchscreen/wacom-wez01.c` or `input/misc`), the way `fts1ba90a.c`
(620 lines) distilled the FTS driver — dropping `sec_input`/`sec_cmd`, the factory
`wacom_i2c_sec.c`, `wacom_i2c_elec.c`, and (for the first cut) `wez01_flash.c`.

First-cut scope — just make it draw:
1. probe: get `wacom_avdd` regulator, request the three gpios, request the IRQ.
2. power on, `COM_QUERY`, verify `mpu_ver == 0x46`, read max_x/max_y/pressure.
3. register an input device (ABS_X/ABS_Y/ABS_PRESSURE/ABS_DISTANCE/ABS_TILT_X/Y,
   BTN_TOUCH/BTN_TOOL_PEN/BTN_TOOL_RUBBER/BTN_STYLUS).
4. threaded IRQ: read 17 bytes, **log the raw packet during bring-up**, parse per
   the layout above, emit events. Apply xy_switch + invert for the landscape frame.
5. `COM_SAMPLERATE_START` to begin reporting.

Defer to later: firmware flash (`wez01_flash.c`), BLE pen charging, AOP/screen-off
gestures, the garage/dock notifications, factory sysfs.

Wire-in mirrors the others in `linux-postmarketos-qcom-sm8450/APKBUILD`
(`cp` the file, append `obj-y += wacom-wez01.o` to the target dir's Makefile), and
flip the DT `compatible` to whatever string the new driver matches.

## Bring-up status (r44 + driver) — BLOCKED on GPI DMA

The driver (`wacom-wez01.c`) is written and builds into the kernel. On-device it
**binds and works to the edge of the bus**:

- probes, registers input `Wacom WEZ01 S Pen` (event4), requests IRQ (gpio51 →
  virq 187), claims `0x56` (`UU`).
- the IRQ is real: **704 interrupts while drawing** — the digitizer senses the pen
  and signals data-ready.

But **every i2c read on the bus fails**, so no packet is ever parsed and event4
stays silent:

```
gpi a00000.dma-controller: not enough space in ring, avail:0 required:1
geni_i2c a98000.i2c: prep_slave_sg failed
geni_i2c a98000.i2c: GPI transfer failed: -5
```

Root cause chain, established from the mainline sources:

1. **SE14 is hardware-forced to GPI DMA.** `i2c-qcom-geni` reads `fifo_disable`
   from the SE's `GENI_IF_DISABLE_RO` register — SE14's FIFO interface is disabled
   in silicon, so `gpi_mode = true` is forced; there is no FIFO fallback. (This is
   why the FIFO bus i2c8/touch works and i2c14 does not — different HW, not the
   driver.) Small 1-byte reads (`i2cdetect -r`) went through in the probe-only
   boot, but the driver's 17-/32-byte reads all take the GPI path.
2. **The GPI channel's ring is empty from the first transfer.** `gpi.c` reports
   `avail:0` of `CHAN_TRES = 64` on transfer #1. The ring's read pointer only
   advances as GPI *completion events* are processed, so avail:0 at the start
   means the channel was never brought to a running/reset state with credit — a
   GPI channel-start problem, not a ring overrun.
3. It is **persistent**: once wedged, even manual `i2ctransfer` reads keep failing
   until a reset. The level-triggered pen IRQ then storms (failed read never
   deasserts the line) — the console spam the user saw.

The DT wiring is NOT the bug: mainline `sm8450.dtsi` gives i2c14
`dmas = <&gpi_dma1 0 6 QCOM_GPI_I2C>` (SE14 = 7th SE on QUP1 = index 6), which is
correct. i2c8–i2c12 have no `dmas` (FIFO), so **i2c14 may be the first real
consumer of the `gpi_dma1` (a00000) controller** — plausibly why its channel
start path is exercising an untested/broken corner.

Next avenues (not yet tried): confirm `gpi_dma1` actually probed and its GPII for
this channel started (instrument `gpi_alloc_chan`/`gpi_start_chan` in `gpi.c`);
check for a mainline GPI-DMA fix for sm8450 QUP1; compare against a known-good GPI
consumer (a QUP1 SPI in GPI mode). This is a SoC DMA-plumbing problem in the class
of "hard SoC integration," distinct from the driver, which is ready to run the
moment a read succeeds.
