#!/bin/sh
# camtest.sh — stream raw frames from one camera through CAMSS on the tablet.
#
# Usage: sh camtest.sh [uw|front|frontfull|rear] [COUNT] [OUT]
#   uw         rear ultrawide Hi847 on CSIPHY2, 3264x2448 (csid0 -> vfe0)
#   front      front Hi1337 on CSIPHY4, 2032x1524 binned (csid1 -> vfe1)
#   frontfull  front Hi1337 on CSIPHY4, 4000x3000 (csid1 -> vfe1)
#   rear       rear main Hi1337 on CSIPHY1, 4128x3096 (csid2 -> vfe2)
#   COUNT      frames to capture (default 5)
#   OUT        output file (default /home/user/cam-$CAM.raw)
#
# Links SENSOR -> csiphyN -> csidN -> vfeN_rdi0, sets the sensor's native
# format on every pad, then captures COUNT packed 10-bit Bayer frames from
# the RDI video node with v4l2-ctl. Decode on the host with tools/raw2png.py.
# CSID N feeds IFE N only, so each camera has a default CSID/VFE pair;
# VFE=N and CSID=N in the environment override it.
# Needs v4l-utils (apk add v4l-utils). Run as the normal user.
set -e
CAM=${1:-uw}; COUNT=${2:-5}
M="media-ctl -d /dev/media0"
# find_sensor NAME PHY: the sensor entity of that driver linked to that CSIPHY
# (two Hi1337 modules share the driver; the link tells them apart).
find_sensor() { $M -p | awk -v n="$1" -v phy="$2" '/^- entity/ { e = ($0 ~ "entity [0-9]+: " n " [0-9]+-0021") ? $0 : "" } e != "" && $0 ~ "\"" phy "\"" { sub(/^- entity [0-9]+: /, "", e); sub(/ \(.*/, "", e); print e; exit }'; }
case "$CAM" in
uw)        PHY=msm_csiphy2; W=3264; H=2448; DEF=0; SENSOR=$(find_sensor hi847 $PHY) ;;
front)     PHY=msm_csiphy4; W=2032; H=1524; DEF=1; SENSOR=$(find_sensor hi1337 $PHY) ;;
frontfull) PHY=msm_csiphy4; W=4000; H=3000; DEF=1; SENSOR=$(find_sensor hi1337 $PHY) ;;
rear)      PHY=msm_csiphy1; W=4128; H=3096; DEF=2; SENSOR=$(find_sensor hi1337 $PHY) ;;
*)   echo "unknown camera $CAM"; exit 1 ;;
esac
FMT=SGRBG10_1X10; PIX=pgAA
VFE=${VFE:-$DEF}; CSID=${CSID:-$DEF}
[ -n "$SENSOR" ] || { echo "sensor not found in media graph"; exit 1; }
OUT=${3:-/home/user/cam-$CAM.raw}
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
