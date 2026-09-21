#!/bin/sh
# mictest.sh [SECONDS] : mainline microphone probe (issue #7).
# Applies the UCM Mic route, records hw:0,2, samples the DMIC pads 171-174
# with padfreq during the capture, then prints the sample statistics.
D=${1:-12}; W=/tmp/mictest.wav
alsaucm -c Samsung-Galaxy-Tab-S8-Plus set _verb HiFi set _enadev Mic >/dev/null 2>&1
echo "mux0=$(amixer -c 0 cget name='VA DMIC MUX0' | tail -1) mux1=$(amixer -c 0 cget name='VA DMIC MUX1' | tail -1)"
arecord -D hw:0,2 -f S16_LE -r 48000 -c 2 -d "$D" "$W" >/tmp/mictest.log 2>&1 &
sleep 3
for p in 171 172 173 174; do
  printf 'pad %s: ' "$p"; sudo -n /home/user/padfreq "$p" 2 | sed -n 2p
done
wait
python3 - "$W" <<'PY'
import sys, wave, struct
w = wave.open(sys.argv[1]); n = w.getnframes(); d = w.readframes(n)
v = struct.unpack("<%dh" % (len(d) // 2), d); L = v[0::2]; R = v[1::2]
print("frames", n, "L max/min", max(L), min(L), "R max/min", max(R), min(R), "nonzero", sum(1 for x in v if x))
PY
for r in /sys/class/regulator/regulator.*; do
  n=$(cat "$r/name"); case "$n" in vreg_l7b_2p5|vreg_s10b_1p8) echo "$n $(cat "$r/state") $(cat "$r/microvolts")";; esac
done
