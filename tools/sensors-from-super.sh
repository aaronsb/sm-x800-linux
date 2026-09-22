#!/bin/sh
# sensors-from-super.sh — host-side fallback for the sensor registry configs.
#
# gts8pwifi-fw-extract normally reads /vendor/etc/sensors on the tablet by
# mapping the `vendor` logical partition out of `super` (make-dynpart-mappings
# + a read-only F2FS mount). The stock vendor image is F2FS with LZ4
# compression, so that path needs CONFIG_F2FS_FS_COMPRESSION in the tablet
# kernel. Until the kernel has it, do the read on the host, where any
# distribution kernel can mount the image, and hand the result to the
# on-device script, which builds the served tree from it.
#
#   sudo tools/sensors-from-super.sh device-facts/partitions-backup/super.img \
#        --to user@tablet
#
#   --to [USER@]HOST   scp the staged copy to HOST and run
#                      `sudo gts8pwifi-fw-extract --sensors-from` there
#   --out DIR          where to stage on the host
#                      (default root-build/stock-extract/sensors, gitignored)
#
# Needs root for lpunpack's output and the loop mount. Nothing is written to
# the image. The staged copy is Qualcomm's proprietary configuration and
# stays out of git like every other harvest.

set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$SELF_DIR/../root-build/stock-extract/sensors"
SUPER=""
TO=""
WORK=""

die() { echo "!! $*" >&2; exit 1; }

cleanup() {
	[ -n "$WORK" ] || return 0
	umount "$WORK/mnt" 2>/dev/null || true
	rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
	case "$1" in
		--to)  TO=$2; shift 2 ;;
		--out) OUT=$2; shift 2 ;;
		-h|--help) sed -n '2,22p' "$0"; exit 0 ;;
		-*) die "unknown arg: $1" ;;
		*) [ -z "$SUPER" ] || die "one super image only"; SUPER=$1; shift ;;
	esac
done

[ -n "$SUPER" ] || die "usage: sensors-from-super.sh SUPER_IMG [--to [USER@]HOST] [--out DIR]"
[ -f "$SUPER" ] || die "$SUPER not found"
[ "$(id -u)" -eq 0 ] || die "needs root (lpunpack output + loop mount)"
command -v lpunpack >/dev/null || die "lpunpack not found (android-tools)"

# A sparse image (Android "simg", magic ed26ff3a) has to be flattened first.
magic=$(od -An -tx1 -N4 "$SUPER" | tr -d ' \n')
[ "$magic" != "3affffed" ] && [ "$magic" != "3aff26ed" ] \
	|| die "$SUPER is a sparse image; simg2img it to a raw image first"

WORK=$(mktemp -d)
mkdir -p "$WORK/mnt"

echo ">> lpunpack vendor from $SUPER"
lpunpack --partition vendor "$SUPER" "$WORK" >/dev/null \
	|| die "lpunpack of vendor failed"

echo ">> mounting vendor.img (F2FS, read-only)"
mount -t f2fs -o ro,loop,norecovery "$WORK/vendor.img" "$WORK/mnt" \
	|| die "could not mount vendor.img (host kernel needs f2fs with compression)"
[ -d "$WORK/mnt/etc/sensors/config" ] || die "no etc/sensors/config in vendor"

rm -rf "$OUT"
mkdir -p "$OUT/config"
cp "$WORK/mnt/etc/sensors/config"/*.json "$OUT/config/"
cp "$WORK/mnt/etc/sensors/sns_reg_config" "$OUT/"
umount "$WORK/mnt"
n=$(ls "$OUT/config" | wc -l)
echo ">> staged $n configs + sns_reg_config in $OUT"
[ "$n" -gt 0 ] || die "no configs copied"

[ -n "$TO" ] || { echo ">> no --to: copy $OUT to the tablet and run"; \
	echo "   sudo gts8pwifi-fw-extract --sensors-from <dir>"; exit 0; }

echo ">> pushing to $TO and building the served tree there"
ssh "$TO" 'rm -rf /tmp/gts8pwifi-sensors && mkdir -p /tmp/gts8pwifi-sensors'
scp -rq "$OUT/config" "$OUT/sns_reg_config" "$TO:/tmp/gts8pwifi-sensors/"
ssh -t "$TO" 'sudo gts8pwifi-fw-extract --sensors-from /tmp/gts8pwifi-sensors; rm -rf /tmp/gts8pwifi-sensors'
