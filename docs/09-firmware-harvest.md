# Phase 9 — Firmware blob harvest (the cartridge-dump pattern, generalized)

Device: SM-X800 (gts8pwifi), One UI 7 stock. Host: Arch.

Mainline Linux on this tablet needs a handful of Samsung/Qualcomm firmware blobs
that **no repo and no package may ship** — they are copyrighted and, in the GPU's
case, TrustZone-signed for this device. The port already solved this for the GPU
zap shader with a one-off extractor. This phase turns that one-off into a
**manifest-driven pattern**: declare a blob once, and the build harvests it from
the builder's own stock firmware.

## The model

**Cartridge-dump.** We distribute the *extractor*, never the *bytes*. Every blob
lives in the builder's own stock firmware — which they already have, because you
cannot get to a flashable state without it (Odin AP/BL/CSC, One UI ~7.0). The
build reads those blobs out of a partition dump and stages them; nothing
copyrighted ever leaves the owner's device.

## The flow

Harvest happens **once, pre-flash, while the device is still rooted on stock** —
not repeatedly on the running port. That ordering is the point: it lets the build
*prove it has every required blob before the user commits to flashing*, so a bad
or incomplete harvest is caught while the tablet is still trivially recoverable.

1. **Unlock + root on stock** — `docs/01-unlock-root-runbook.md`.
2. **Dump the blob-bearing partitions** off the rooted device. Harvest needs
   **`apnhlos`** (the zap) and **`super`** (everything else) at minimum, and the
   boot image build needs **`boot`** for the stock ramdisk. `make dumps ADB=1`
   pulls all three from the rooted tablet into `device-facts/partitions-backup/`
   and verifies each against the on-device sha256; without `ADB=1` it only checks
   what is already there (the runbook's step 8).
3. **Turn the raw images into source roots** on the host:
   - `apnhlos` — plain vfat: `mount -o ro,loop apnhlos.img /mnt/apnhlos`
   - `vendor`  — F2FS (LZ4-compressed) logical image inside `super`:
     `lpunpack --partition vendor super.img . && mount -o ro,loop vendor.img /mnt/vendor`
   (`tools/fw-harvest.sh --from-dumps DIR` does both when lp tooling and F2FS support are present.)
4. **Harvest, offline, at leisure**, before flashing. `make harvest` runs
   `tools/fw-harvest.sh --from-dumps` on the dumps directory and
   `tools/sensors-from-super.sh` for the sensor registry configs; by hand:
   ```sh
   tools/fw-harvest.sh --apnhlos /mnt/apnhlos --vendor /mnt/vendor \
                       --out root-build/stock-extract/harvest
   ```
5. **Build gate.** `make check` reports whether the dumps and the harvested zap
   are present before anything is built, and `make stage-fw` (run by every boot
   image build) HARD-FAILS if the zap does not land in the initramfs.

## The manifest

One row per blob in [`tools/fw-manifest.tsv`](../tools/fw-manifest.tsv); the
harvester reads it and `--list` prints it. Columns: `name, source, src_glob,
dest_dir, tier, class, status, notes`. To enroll a new blob, add a row — no new
script.

| name | source | class | status | what it is |
|---|---|---|---|---|
| `a730_zap`   | apnhlos | pil | working | GPU zap shader — the working reference |
| `wez01_pen`  | vendor  | mcu | wip     | **S Pen** Wacom W90xx digitizer (i2c 0x56) |
| `fts_touch`  | vendor  | mcu | working | Touchscreen (STM FTS1BA90A) — already ported |
| `stm32_pogo` | vendor  | mcu | working | Pogo keyboard MCU — already ported |
| `camera_icp` | vendor  | pil | none    | Camera ISP microcontroller |
| `eva`        | vendor  | pil | none    | EVA computer-vision engine |
| `vpu`        | vendor  | pil | none    | Iris video codec (signed + `_unsigned` both ship) |
| `cs35l45`    | vendor  | dsp | none    | Cirrus speaker-amp DSP (audio path) |
| `cs40l26`    | vendor  | dsp | none    | Cirrus haptics DSP |
| `mfc`        | vendor  | mcu | none    | Wireless-charging IC MCU |
| `ois`        | vendor  | mcu | none    | Camera OIS STM32G MCU |

## Three classes of blob (and where the S Pen actually sits)

The exploration that kicked this off asked whether the pen is a signed blob we
can extract "like the GPU." It is extractable — but it is **not** the GPU's
class, and the distinction is what makes the manifest have a `class` column:

- **`pil`** — Qualcomm PIL/MDT images (`.mdt` + `.bNN` splits), ELF Xtensa,
  **TrustZone-authenticated**: the SoC's secure world refuses to load them
  without Samsung's signature. The zap is one. Camera ICP, EVA, and VPU are the
  other esoteric ones. These are the true "signed blobs."
- **`mcu`** — a raw firmware image the peripheral's **own driver flashes over
  i2c/spi**. No SoC signature gate. The **S Pen** (`wez01_gts8p.bin`),
  touchscreen, and pogo keyboard are all this class — which is why the pen is the
  *gentlest* introduction: no signing to satisfy. The hard part is the mainline
  Wacom driver + I²C bus + DT node, not the blob. The downstream driver already
  sits in `kernel-src/drivers/input/wacom/` (`compatible = "wacom,w90xx"`,
  `wacom,fw_path`, `wacom,use_garage` = the pen dock).
- **`dsp`** — Cirrus codec firmware (`.wmfw` + tuning `.bin`), loaded by ASoC at
  card probe. The `cs35l45` amp is live on the (still-blocked) audio path.

## Status

- **Built and tested:** the manifest + `tools/fw-harvest.sh`, validated against
  the local `super`/vendor dump — 10/10 vendor blobs harvested, PIL split-sets
  handled (24 `CAMERA_ICP.*`, 22 `evass.*`, 4 `vpu`), `apnhlos` skipped cleanly
  when not supplied.
- **Wired into the Makefile:** `make dumps` (verify or pull the dumps),
  `make harvest` (`fw-harvest.sh --from-dumps` plus the sensor registry), and
  `make check` reporting the zap's presence; `make stage-fw` still gates only the
  zap. `make check` also lists the host tools harvest needs (lpunpack and an
  erofs reader).
- **Not yet wired:** a per-blob gate that reads the manifest (generalize `make
  stage-fw` / `60-gts8pwifi-gpu-fw.files` to hard-fail per required blob).
- **Relationship to the on-device extractor:** `gts8pwifi-fw-extract` (runtime,
  mounts `apnhlos` on the running port) stays as a fallback for the zap. The
  pre-flash harvest is the primary, scalable path.
