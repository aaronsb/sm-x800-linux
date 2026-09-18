#!/bin/sh
# gts8pwifi-fw-extract — pull non-redistributable firmware off the device's
# own stock partitions into /lib/firmware, then rebuild the initramfs.
#
# The cartridge-dump model: this port's repo and packages ship only OPEN or
# redistributable content. Blobs that are Samsung-signed for THIS device
# (the a730 GPU zap shader and the audio DSP image, which TrustZone will only
# accept with Samsung's signature) are extracted at setup time from partitions the device
# already carries — nothing copyrighted is ever distributed by us.
#
# Idempotent; run once after any userdata/rootfs reflash (see tools/README).

set -e

FWDIR=/lib/firmware/qcom/sm8450/gts8pwifi
MNT=$(mktemp -d)

cleanup() { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

echo ">> mounting apnhlos (stock firmware partition, read-only)"
mount -o ro /dev/disk/by-partlabel/apnhlos "$MNT"

mkdir -p "$FWDIR"
for f in a730_zap.mdt a730_zap.b00 a730_zap.b01 a730_zap.b02; do
	if [ ! -f "$MNT/image/$f" ]; then
		echo "!! $f not found in apnhlos/image — wrong partition layout?" >&2
		exit 1
	fi
	cp "$MNT/image/$f" "$FWDIR/$f"
	echo "   $f -> $FWDIR/"
done

# Audio DSP: split adsp.mdt + adsp.bNN segments (some segment numbers are
# absent by design; the mdt loader skips zero-size PT_LOADs). SM8450 ships
# no adsp_dtb. The *.jsn protection-domain maps are not needed by the
# in-kernel pd-mapper; they are kept beside the image for a userspace
# pd-mapper, should one ever be used.
echo ">> staging audio DSP image"
if [ ! -f "$MNT/image/adsp.mdt" ]; then
	echo "!! adsp.mdt not found in apnhlos/image" >&2
	exit 1
fi
cp "$MNT"/image/adsp.mdt "$MNT"/image/adsp.b* "$FWDIR"/
cp "$MNT"/image/adspua.jsn "$MNT"/image/adspr.jsn "$FWDIR"/ 2>/dev/null || true
echo "   adsp.mdt + $(ls "$FWDIR"/adsp.b* | wc -l) segments -> $FWDIR/"

echo ">> regenerating initramfs (a7xx needs GPU firmware at bind time)"
mkinitfs

echo ">> done. GPU + ADSP firmware staged; effective from the next boot of a"
echo "   boot image built against this rootfs (or this rootfs's own /boot)."
