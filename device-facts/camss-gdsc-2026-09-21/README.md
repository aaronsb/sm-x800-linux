# camcc register dumps around the second-stream GDSC failure, 2026-09-21

Kernel r16 (7.2 with sm8450-camss, hi847-of, camcc-sm8450-retain-ff and
camss-sm8450-camnoc-idle). Tablet 192.168.2.123, rear ultrawide Hi847 on
CSIPHY2, `tools/camtest.sh uw 5` for each stream.

| File | State |
|---|---|
| `camcc-A.bin` | after boot: sensor probed over CCI, TITAN_TOP collapsed once, no stream yet |
| `camcc-B.bin` | after one 5-frame RDI stream on VFE0 and the following collapse |
| `camcc-C.bin` | after the failed second power-up (`titan_top_gdsc status stuck at 'off'`) |
| `gcc-cam-A.bin`, `gcc-cam-B.bin` | gcc 0x136000 to 0x137000 (camera AHB/AXI/XO branches) in states A and B, identical |
| `camcc-diff.txt` | the words that differ, with names from camcc-sm8450.c |

Dumps are 0x20000 bytes from physical 0xade0000 read through /dev/mem with
`dumpreg.py BASE SIZE OUT`; `rdreg.py ADDR...` and `wrreg.py ADDR VAL` read and
write single words. camcc is always-on, so reading it is safe; the camera
blocks themselves (0xac00000 range) are not, while their GDSC is off.

Reading: between A and B the only persistent changes are PLL0 and PLL3
calibrated once, the streamed RCGs configured, and the read-only status word
after each streamed clock's CBCR. Between B and C several RCG roots report
"on" and the TITAN_TOP GDSC shows the stuck power-up signature GDSCR
0x68282800, CFG_GDSCR 0x010e0000. The GDSC and clock state that software can
see is otherwise identical before a working power-up and before a failing one.
The measurement record and the experiment matrix are in issue #27.

Outcome: the RCG selectors that stayed on PLL sources (0x1101c 0x601, 0x13178
0x105, 0x13198 0x203, 0x11050 0x105) were the fault. camcc-sm8450 used plain RCG
ops, so a disabled RCG kept its PLL parent while the PLL powered down; the GDSC
power-up then waited on a clock that never toggled. Fixed by
`camcc-sm8450-shared-rcg.patch` (clk_rcg2_shared_ops park the RCGs on XO).
