#!/bin/sh
# camtest.sh — stream raw frames from one camera through CAMSS on the tablet.
#
# Usage: sh camtest.sh [uw] [COUNT] [OUT]
#   uw     rear ultrawide Hi847 on CSIPHY2 (the only sensor so far)
#   COUNT  frames to capture (default 5)
#   OUT    output file (default /home/user/cam-$CAM.raw)
#
# Links SENSOR -> csiphyN -> csid0 -> vfe0_rdi0, sets the sensor's native
# format on every pad, then captures COUNT packed 10-bit Bayer frames from
# the RDI video node with v4l2-ctl. Decode on the host with tools/raw2png.py.
# VFE=N (default 0) picks the VFE whose rdi0 receives the stream, CSID=N (default 0) the CSID.
# Needs v4l-utils (apk add v4l-utils). Run as the normal user.
set -e
CAM=${1:-uw}; COUNT=${2:-5}; VFE=${VFE:-0}; CSID=${CSID:-0}
case "$CAM" in
uw)  SENSOR=$(media-ctl -d /dev/media0 -p | sed -n 's/^- entity [0-9]*: \(hi847 [0-9]*-0021\).*/\1/p' | head -1)
     PHY=msm_csiphy2; FMT=SGRBG10_1X10; W=3264; H=2448; PIX=pgAA ;;
*)   echo "unknown camera $CAM"; exit 1 ;;
esac
[ -n "$SENSOR" ] || { echo "sensor not found in media graph"; exit 1; }
OUT=${3:-/home/user/cam-$CAM.raw}
M="media-ctl -d /dev/media0"
F="fmt:$FMT/${W}x${H}"

$M -r
$M -l "\"$PHY\":1->\"msm_csid${CSID}\":0[1]"
$M -l "\"msm_csid${CSID}\":1->\"msm_vfe${VFE}_rdi0\":0[1]"
for pad in "\"$SENSOR\":0" "\"$PHY\":0" "\"$PHY\":1" "\"msm_csid${CSID}\":0" "\"msm_csid${CSID}\":1" "\"msm_vfe${VFE}_rdi0\":0" "\"msm_vfe${VFE}_rdi0\":1"; do
	$M -V "$pad[$F]"
done
VID=$($M -e msm_vfe${VFE}_video0)
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=$PIX
echo ">> $SENSOR -> $PHY -> msm_csid${CSID} -> msm_vfe${VFE}_rdi0 -> $VID, ${W}x${H} $FMT"
timeout 30 v4l2-ctl -d "$VID" --stream-mmap=4 --stream-count="$COUNT" --stream-to="$OUT" --verbose 2>&1 | grep -E "dqbuf|error|fail" || true
ls -la "$OUT"
echo ">> frame size $(v4l2-ctl -d "$VID" --get-fmt-video | sed -n 's/.*Size Image *: *//p') bytes; decode: python3 tools/raw2png.py $OUT $W $H out.png"
