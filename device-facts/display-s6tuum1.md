# Display: S6TUUM1 AMSA24VU01 (WQXGA AMOLED) — extracted facts

Source: stock DTB panel node (`ss_dsi_panel_S6TUUM1_AMSA24VU01_WQXGA`,
stock-fdt.dts ~30455) and the downstream techpack driver
(`kernel-src/techpack/display/msm/samsung/S6TUUM1_AMSA24VU01/`). Gathered for
the mainline `drm_panel` port; everything here is from GPL-licensed DT/driver
sources.

## Geometry and mode

- **2800 x 1752 landscape raster** (PPS pic_width 0x0af0 / pic_height 0x06d8;
  timing node width 0xaf0, height 0x6d8). Matches the bootloader framebuffer
  scanout — the DDIC raster is landscape, no rotation needed.
- **Command mode** (`dsi_cmd_mode`), TE-driven, 4 lanes, 24 bpp input.
- Two timings: 120 Hz (init writes reg 0x60 = 0x20) and 60 Hz (0x60 = 0x00);
  `samsung,vrr_tx_cmds` switches at runtime.
- Porches (from 120 Hz timing): h pw/bp/fp = 64/48/64, v pw/bp/fp = 64/48/48.
- Panel clock 1 530 000 000 (0x5b31f280), dynamic MIPI clock table present.
- PHY timings: `00 35 0d 0d 1f 27 0d 0d 0c 02 04 00 2a 12`.

## DSC (this panel IS compressed — buried in the command stream, not DT props)

From the 88-byte PPS sent via DDIC command 0x9E, preceded by a MIPI
compression-mode packet (type 0x07, payload 0x01):

- DSC **1.1**, 8 bpc, 8 bpp, block prediction enabled
- slice 1400 x 12 → **2 slices/line**, chunk size 1400
- initial_xmit_delay 512, initial_dec_delay 0x03bd
- Plan: fill `drm_dsc_config` and let `drm_dsc_pps_payload_pack()` build the
  PPS instead of replaying Samsung's raw bytes.

## Power / control

- **One power rail**: `panel_ldo_en` — regulator-fixed on **tlmm gpio 34**,
  enable-active-high, boot-on in stock (why the splash survives). Supply
  entry: 1.8 V nominal, post-on sleep 11 ms, pre-off sleep 15 ms.
- **Reset: tlmm gpio 0**; **TE: tlmm gpio 86**.

## Command sequences (qcom cmd stream format: type,last,vc,ack,wait,len16,payload)

- **on-command** (DDIC setup, sent after sleep-out): `d3 4d`; `98 00`;
  `60 20` (+50 ms wait; 0x00 for 60 Hz); reg-pointer writes
  `b0 00 08 78`/`78 30`, `b0 00 39 78`/`78 3c`, `b0 00 3e 78`/`78 3c`;
  compression-mode(0x07) = 01; 0x9E + PPS; `9a 00`; `79 02`; `86 0a 6b`;
  `b0 00 08 5d`; `5d 00`.
- **display on**: DCS 0x29, 17 ms wait. (`first_display_on` additionally does
  `f8 5800d01d`-style writes — factory path, ignored.)
- **display off**: DCS 0x28, then DCS 0x10 (sleep-in) + 100 ms.
- **brightness**: DCS 0x51, 16-bit (gamma_mode2), plus 0x53 = 0x20
  (dimming ctrl) in init. HBM path exists (`gamma_mode2_hbm`), ignored for
  now.
- Sleep-out (0x11) is issued by the downstream driver itself, not in DT:
  order is power → reset → 0x11 → wait → on-command → 0x29.

## Mainline plan

Model on `panel-samsung-s6e3ha8.c` (same tree: Samsung DDIC, DSC, cmd mode).
DTS: mdss/dsi0/dsi0_phy enables (phy vdds = l5b 0.88, dsi vdda = l6b 1.2 per
HDK), panel node with vdd-supply/reset-gpios, TE pinctrl (gpio 86,
mdp_vsync). Config: DRM_MSM=y. Keep the splash reserved-memory and the
clk/pd_ignore_unused bootargs for the first bring-up; retire them once the
native driver holds the display path.

## Bring-up findings (r30–r34, first light)

**Working (r34, splash-takeover mode):** native KMS on msm/DPU with fbcon at
2800x1752 — the panel displays our frames, DCS brightness control works live
(`/sys/class/backlight/ae94000.dsi.0`). Takeover mode = prepare/enable do NOT
touch the panel (no reset, no init); the ABL-initialized, TE-running,
DSC-configured panel is driven as-is.

**Fixed along the way:**
- DSC topology: this tree hardcodes 1:1:1 for DSC panels (mid-rework);
  2800px needs 2 LM. Patched width-aware (dpu-dsc-topology-wide-mode.patch).
- DRM_MSM needs python3 in makedepends (register header generation).

**Open bugs, fully characterized:**
1. **2x2 tiling**: console renders as four perfectly legible copies in a 2x2
   grid — an exact 4x geometry mismatch between DPU dual-DSC encode and panel
   decode. prep_dsc's per-encoder split looks right at a glance; suspicion is
   the incomplete upstream DSC rework in this snapshot (dpu_hw_dsc / merge
   programming). Fix path: cherry-pick the completed rework from upstream
   (our base IS next-new HEAD; no newer branch snapshot to rebase to).
2. **TE/rd_ptr never reaches the encoder**: kickoffs run on 96ms timeouts
   (sluggish refresh, 'prepare for kickoff' spam). TE pulses DO arrive at the
   hw — they land on an unclaimed irq [12,2] (INTF1 tear block) while the cmd
   encoder never registers an rd_ptr callback there. Same rework suspicion.
3. **Cold init kills the panel**: r30-r33 all showed the bootloader's display
   dying at our reset pulse (exactly 7 TE pulses = ABL's display counted
   between irq-enable and our reset), and our init never revived it — while
   command TRANSPORT is proven good (brightness DCS works). Suspects: reset
   on tlmm gpio0 (verify it really is the panel reset / not TZ-guarded), or a
   sequencing prerequisite ABL performs. Takeover sidesteps this entirely;
   cold init only matters for panel power cycling / suspend.
