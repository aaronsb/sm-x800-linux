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
- **Reset: tlmm gpio 0**; **TE: tlmm gpio 86**; **TCON-ready: tlmm gpio 1**
  (`samsung,tcon-rdy-gpio`). The DDIC is an Anapass TCON
  (`samsung,anapass-power-seq`): it boots for ~330 ms after reset and must
  not be sent commands until the ready pin goes high (downstream
  `wait_tcon_ready`: flat 200 ms sleep + poll up to 300 ms).

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

## Bring-up findings (r30–r38: first light → fully working)

**Final state (r38): the native display path is DONE.** Cold init from our
own reset, DSC at full 2800x1752, TE-synced kickoffs, DPMS power cycling
(blank/unblank re-runs the whole init), and correct brightness. The r34
"takeover mode" scaffolding is removed.

**Historical (r34, splash-takeover mode):** native KMS on msm/DPU with fbcon
at 2800x1752 — the panel displays our frames, DCS brightness control works
live (`/sys/class/backlight/ae94000.dsi.0`). Takeover mode = prepare/enable
do NOT touch the panel (no reset, no init); the ABL-initialized, TE-running,
DSC-configured panel is driven as-is.

**Fixed along the way:**
- DSC topology: this tree hardcodes 1:1:1 for DSC panels (mid-rework);
  2800px needs 2 LM. Patched width-aware (dpu-dsc-topology-wide-mode.patch).
- DRM_MSM needs python3 in makedepends (register header generation).

**All three bugs RESOLVED (r35-r38). What they actually were:**

1. **2x2 tiling** (fixed r35): the snapshot's `dpu_encoder_use_dsc_merge()`
   hardcoded num_dsc = 1 (mid-rework state), so DSC_MODE_MULTIPLEX was never
   set: each DSC encoder was programmed for both slices (2800px) while fed
   one (1400px), and the pingpongs never merged the halves. One backported
   hunk of upstream b6090ffb30f3 (count the real hw_dsc blocks) fixed it —
   the rest of the DSC path in the snapshot was already final-form.
2. **Kickoff timeouts** (fixed r35): same bug, not a separate one. With the
   stream misframed, pp_done never fired (ctl_start 9240 / pp_done 0);
   with the merge fix, ctl_start == pp_done every frame and the TE rd_ptr
   irq registers and fires normally. There never was a TE routing problem.
3. **Cold init kills the panel** (fixed r37): the DDIC is an **Anapass TCON**
   (stock `samsung,anapass-power-seq`) that BOOTS after reset (~330 ms
   measured) and signals readiness on **tlmm gpio 1** (stock
   `samsung,tcon-rdy-gpio`). Our init fired ~10 ms after reset, straight
   into a booting TCON — every command silently void, no DSI errors.
   Downstream sequence: VDD on → LP11 → reset → **wait TCON RDY high**
   (flat 200 ms + poll ≤300 ms) → HS commands. Mirroring that in prepare()
   fixed cold init outright; DPMS off/on (full panel power cycle + re-init)
   verified working live.

**The "panel randomly goes black" postscript (fixed r38):** brightness, not
display. DBV on this DDIC is **11 bits** (downstream fills 0x51 with
DBV[7:0] then DBV[10:8]; candela table tops out at 0x7ff = 420 nits).
Values above 2047 wrap — writing 2048 lands as DBV 0, a perfectly black
screen on working hardware. Byte order is DCS-standard little-endian
(`51 d8 0d` = 0x0dd8), so use mipi_dsi_dcs_set_display_brightness (not
`_large`, which explains r34's "very dim": its swapped bytes decoded to
DBV ≈ 13). Driver now advertises max_brightness 0x7ff, default 0x5d8.

**Still stock-only (not needed so far):** `samsung,delayed-display-on = <1>`
(downstream sends 0x29 only after the first frames, "to avoid garbage image
output from wakeup" — we send it in enable() and have seen no garbage);
ESD recovery irqs; VRR runtime switching (we init 120 Hz fixed).
