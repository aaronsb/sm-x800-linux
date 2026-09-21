# Phase 10: audio — four CS35L45 amps, an ADSP, and one wrong data line

Audio was the README's "blocked twice over": no ADSP firmware, and no MI2S
path in AudioReach. Both turned out to be wrong, and a third and fourth
problem were hiding behind them. This phase took two flashes (r45, r46) and
one on-device topology swap. The trigger was the Galaxy Tab S9 ports
(nacht20-de/gts9wifi-fedora, agcarbajo/postmarketos-galaxy-tab-s9-ultra),
which run the same amplifiers on the same LPASS interface, and whose notes
pointed at every one of the four fixes.

## The hardware

Stock DTB, `qupv3_se4_i2c` (mainline i2c4, downstream alias i2c18): four
Cirrus CS35L45 amplifiers at 0x30 rear-left, 0x31 front-left, 0x32
rear-right, 0x33 front-right, sharing reset on tlmm 18 and interrupt on
tlmm 19. They take Primary MI2S on gpio126 (sck), gpio129 (ws), gpio127
(`mi2s0_data0`, amp TX back to the DSP) and gpio128 (`mi2s0_data1`, DSP
playback out). Samsung runs it as 4-slot TDM; we run it as 2-channel I2S,
so each speaker pair shares a channel. No WCD codec, no SoundWire; the mics
are DMICs into the VA macro (not wired yet).

Everything LPASS-side runs through AudioReach on the ADSP: the DSP owns the
I2S port, the machine driver only names the graph.

## Fix 1: the ADSP firmware was never missing

`adsp.mdt` + `adsp.b00-b24` sit in the `apnhlos` partition next to the GPU
zap we were already extracting. SM8450 has no separate `adsp_dtb`.
`gts8pwifi-fw-extract` now stages it, the DTS enables `remoteproc_adsp`
with `firmware-name = "qcom/sm8450/gts8pwifi/adsp.mdt"`, and the kernel
gets `QCOM_Q6V5_PAS`, `QCOM_PD_MAPPER` and `QRTR` built in. The in-kernel
pd-mapper answers the `avs/audio` service-registry lookup, so no userspace
daemon and no `.jsn` files are needed.

First boot: "segment outside memory range". Samsung's image is 59 MiB of
relocatable segments; `sm8450.dtsi` reserves 33 MiB for the QRD image at a
different base. The DTS now overrides `adsp_mem` (0x84500000, 0x3b00000)
and the two neighbours that moved with it, `video_mem` and
`cdsp_secure_heap`, verbatim from the stock reserved-memory table. Second
boot: `remote processor adsp is now up`, and the LPASS clock consumers that
had been deferring since phase 5 (LPI pinctrl, codec macros) resolve.

## Fix 2: MI2S had no path in 6.13 because nobody set the format

Pinned tree: `q6apm-lpass-dais` defined `q6i2s_set_fmt()` but never linked
it into the I2S DAI ops, so the CPU DAI's format stayed zero, the I2S
interface module's `ws_src` defaulted to "external", and no bit clock ever
ran. Mainline fixed this in September 2025 with three small commits, now
carried as `tools/mkpatch` backports:

- `q6apm-lpass-dais-i2s-set-fmt` (33b55b94bca9): wire `.set_fmt`.
- `audioreach-i2s-lpaif-type` (5f1af203ef96): pass `lpaif_type` so the DSP
  votes the right clock.
- `sc8280xp-mi2s-dai-format` (596e8ba2faf0): the machine driver tells the
  CPU DAI it provides bit clock and frame sync on MI2S links.

Fix 3 is the codec half of the same story. The machine driver never told
the codec DAIs anything, so the CS35L45 kept its reset-default format and
was never given the bit clock rate to lock its PLL to.
`sc8280xp-mi2s-codec-fmt-sysclk` (the Tab S9 Ultra patch, rebased) sets
I2S/NB_NF/consumer on every codec of an MI2S link and hands it 1.536 MHz
(48 kHz x 16 bit x 2 channels, what the BE fixup pins).

## Fix 4: everything ran, and the speakers were silent

After the reserved-memory fix the card registered, `aplay` ran a full
stream with every DAPM widget on the amp side On (Playback, ASP_RX1,
DACPCM Source, AMP, AMP Enable, SPK; bias On; PLL reference = BCLK at the
1.536 MHz id), and nothing came out.

The topology. q6apm loads `qcom/sm8450/<card model>-tplg.bin`, and the
SM8450 HDK topology in linux-firmware already has the PRIMARY_MI2S_RX
graph, so the first pass just pointed our model name at it. The HDK puts
its I2S data on serial line SD0. This tablet's playback line, gpio128, is
SD1; SD0 (gpio127) is the amplifiers' TX line. The DSP was streaming into
the wrong pin. The Tab S9 Ultra notes say exactly this ("playback exits
via gpio128, not SD0") and their topology was re-pointed at SD1.

The line index is a `(token 256, value)` u32 pair in the compiled file,
SD0 = 1, SD1 = 2. `tools/mk-tplg.py` derives
`Samsung-Galaxy-Tab-S8-Plus-tplg.bin` from the HDK file by changing that
one value, with a check that it sits in the I2S module's tuple array; the
result ships in the device package (BSD-3-Clause upstream). A proper m4
build with `SD_LINE_IDX_I2S_SD1` is the long-term form once `alsatplg` is
in the build path. With SD1 in place, the first thing the speakers ever
played on mainline was, at the owner's request, Rick Astley.

## Userspace

- UCM: `conf.d/sm8450/Samsung-Galaxy-Tab-S8-Plus.conf` +
  `Qualcomm/sm8450/gts8pwifi/HiFi.conf`. The verb routes MultiMedia1 to
  PRIMARY_MI2S_RX; the Speaker device enables the four amps; the boot
  sequence pins the per-amp volumes and splits stereo (left amps on
  ASP_RX1, right amps on ASP_RX2). PulseAudio, the audio server on this
  postmarketOS image, creates `alsa_output.platform-sound.HiFi__Speaker__sink`
  and `alsa_input.platform-sound.HiFi__Mic__source` from it with no help.
  Inspect with `pactl list cards`; `wpctl` stays empty on purpose, because
  the `pulseaudio-wireplumber` shim disables WirePlumber's audio profile.
- Volume is deliberately capped (Digital PCM Volume 420 of 457, about 9 dB
  of headroom). The Cirrus speaker-protection DSP firmware is not loaded, so
  nothing limits excursion in hardware. Raise the cap only with protection.
- `90-gts8pwifi-cs35l45-no-hibernate.rules` keeps the amps out of runtime
  suspend: after a hibernate cycle the driver trusts its cached PLL config
  while the part came back with it cleared, and stays silent.

## Microphones: wired, silent for months, powered from L12C

The capture side is described and probes: three DMIC pairs on LPI gpio6/7,
8/9 and 12/13 (stock `cdc-dmic01/23/45`, mainline functions `dmic1..3`),
the VA macro enabled with those pin states, and an "Internal DMIC Capture"
link from `VA_CODEC_DMA_TX_0` to `<&vamacro 0>`. `arecord -D hw:0,2`
streamed exact digital zeros until 2026-09-21, when declaring L12C
always-on brought all three microphones up.

What was established, in order:

- The DMA lane is right. `TX_CODEC_DMA_TX_3` (what sm8450-hdk wires its VA
  link to) fails with -EIO here, as it does on the Tab S9 Ultra; the VA
  lane streams.
- The VA macro is fully configured during capture: MCLK on, DMIC0 clock
  enabled, decimators 0/1 clocked at 48 kHz and fed from the DMIC mux, and
  the HPF zero-gate open (`TX_PATH_SEC2` bit 0 set). Register dump in the
  session log; nothing in dmesg.
- Every DAPM widget on the path is On, including `DMIC0 Pin` and the VA
  macro's `vdd-micb` supply widget stays Off because the driver never
  routes it (the S9 Ultra port hit the same and made its rail always-on).
- A sweep over all eight `VA DMIC MUXn` inputs at 600 kHz (stock VA
  value) and 4.8 MHz (S9 Ultra) gives exact zeros everywhere. At 2.4 MHz
  (stock's TX-macro capture rate, kept in the DTS) DMIC4/5 on gpio12/13
  return a single exponential decay from about -0.2 full scale to zero in
  the first 100 ms and nothing after: the decimator's high-pass filter
  settling on a flat, low PDM line. Still not a microphone.
- Declaring the two stock 1.7-3.0 V LDOs with no DT consumer (L4C, L5C)
  always-on at their stock 1.8 V init changed nothing; reverted. Same
  for L2C (stock's sensor_vdd for the SLPI hub, a plausible shared
  sensor/mic rail): enabled at 1.8 V, still flat; reverted.
- Stock's audio HAL (`/vendor/etc/audio/sku_taro/mixer_paths.xml` in the
  super dump) maps the mics: main = DMIC1, sub = DMIC3, third = DMIC5,
  fourth = DMIC7, one mic per pin pair on the odd index. Regular
  recording goes through the TX macro (`TX DMIC MUX0 = DMIC1`, 2.4 MHz);
  voice activation through the VA macro (`VA DEC0 MUX = MSM_DMIC`,
  `VA DMIC MUX0 = DMIC1`), the same controls this port sets. All three
  inputs recorded flat here.
- The VA GFMux at 0x3420000 (stock `qcom,va-island-mode-muxsel`) reads
  0 on mainline; downstream writes 1 while the VA macro runs from the
  TX core clock. Writing 1 at runtime through /dev/mem stalls capture
  with -EIO until reboot, so 0 is the working select and mainline is
  right to leave it.
- The mainline TX macro takes DMICs only over SoundWire, so stock's
  regular-capture path (TX macro at 2.4 MHz) has no mainline equivalent.
- The pad level is observable after all. The LPI pads are egpio pads
  shared with the TLMM, and the TLMM's GPIO_IN_OUT register of TLMM 171
  (LPI gpio6, pair 1 clock) and 172 (LPI gpio7, pair 1 data) reads the
  live pad. `tools/padsample.py` samples it. During capture 171 toggles
  at 50/50 duty and 172 never moves (2026-09-21). The clock leaves the
  SoC; the mic sends nothing.
- With that probe as the criterion: every rail stock holds on at idle
  and mainline did not declare (L13C 3.0 V, L2C 1.8 V, L7E 2.8 V) was
  made always-on, the grip-sensor LDO enable (TLMM 180) and the five
  island pads the stock sensor hub drives (184, 185, 188, 189, 202) were
  driven high, and the SLPI itself was booted. The data pad stayed flat
  through all of it. The declarations were removed again; the SLPI stays
  enabled.
- The VA clock mux at 0x3420000 is not a difference: downstream only
  writes it when it requests the VA core clock, and stock's recording
  runs the TX macro from TX_CORE_MCLK at 19.2 MHz, the same PRM clock
  mainline's VA macro holds.

- A second rooted stock session (`device-facts/stock-runtime/2026-09-21/`)
  ruled the sensor hub out: with the SLPI remoteproc stopped, the camera
  app still records sound. During that recording all four pads 171 to
  174 toggle, L2C and L13C drop a use count when the SLPI stops (they
  are sensor rails), and no PMIC rail or GPIO changes for recording.
  Stock captures `TX DMIC MUX0 = DMIC3`, `TX DMIC MUX1 = DMIC1`.
- `tools/padfreq.c` samples one pad at about 1 MS/s. On the clock pad it
  counts 0.75 transitions per read at a 0.999 µs period, which fits a
  2.4 MHz square wave and nothing slower; the DMIC clock rate was right.
- L7B (2.504 V, UFS VCC on stock, disabled on mainline) always-on: data
  pads flat. Reverted.
- L12C always-on: pads 172 and 174 toggle with their clocks and the
  capture carries the room. L12C is stock's only `regulator-always-on`
  LDO. Issue #7 had argued that the bootloader's vote keeps it on under
  mainline; the pad says the rail was off until the DTS declared it.
- Mic map, one `VA DMIC MUXn` input at a time: DMIC0 empty, DMIC1
  (bottom), DMIC2 and DMIC3 (back) carry microphones. The UCM `Mic`
  device captures DMIC1/DMIC3, stock's stereo pair.

The DTS declares `vreg_l12c_1p8` always-on and names it as the VA macro's
`vdd-micb`; the supply widget is unrouted in 7.2, so the flag does the
work. Issue #7 holds the measurements.

Speaker-protection firmware for the follow-up sits in the vendor
partition of the super dump: `/vendor/firmware/cs35l45-dsp1-spk-prot.wmfw`,
`.bin` and `-calib.bin`.

## What is not done

- Microphones: see above.
- 4-slot TDM as Samsung runs it: the AudioReach TDM backend landed in
  ASoC for 7.3 (Prasad Kumpatla, August 2026). Until then the amp pairs
  share I2S channels.
- Speaker-protection firmware (`cs35l45-dsp1-spk-prot.wmfw` + tuning from
  Samsung's published sources) and the volume cap that depends on it.
- One `CMD timeout for [1001021]` (APM_CMD_GET_SPF_STATE) at q6apm probe.
  Harmless so far; the card still comes up.
- `sm8450-mainline/linux` has been dormant since August 2025; both Tab S9
  ports run vanilla 7.2-rc3 plus a short patch stack. Moving this port onto
  mainline is the next big lever (TDM, USB flattening, the PCIe iommu-map
  fix, and dropping four of our five audio patches).
