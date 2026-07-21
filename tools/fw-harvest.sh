#!/bin/sh
# fw-harvest.sh — offline blob harvester for gts8pwifi.
#
# Reads tools/fw-manifest.tsv and copies the named Samsung/Qualcomm blobs out of
# a pre-flash stock-firmware partition dump into a staging tree, then reports
# coverage. Nothing here writes to a device or to flash — it only reads mounted
# source roots and writes into --out.
#
# The intended flow (see docs/09-firmware-harvest.md):
#   1. Unlock + root the tablet on stock (docs/01-unlock-root-runbook.md).
#   2. dd the blob-bearing partitions off the rooted device: `apnhlos` and
#      `super` (the runbook's step-8 backup already does this).
#   3. Turn those raw images into source roots:
#        apnhlos:  mount -o ro,loop apnhlos.img  /mnt/apnhlos
#        vendor:   lpunpack --partition vendor super.img .  &&  \
#                  mount -o ro,loop vendor.img  /mnt/vendor
#      (--from-dumps does this for you when erofs/lp tooling is present.)
#   4. Harvest into a staging tree, at leisure, on the host — BEFORE flashing:
#        tools/fw-harvest.sh --apnhlos /mnt/apnhlos --vendor /mnt/vendor \
#                            --out root-build/stock-extract/harvest
#   5. The build stages from that tree and HARD-FAILS if a required blob is
#      missing, so a bad harvest is caught before the user ever flashes.
#
# Usage:
#   fw-harvest.sh [--manifest F] [--apnhlos DIR] [--vendor DIR] [--out DIR]
#                 [--only NAME[,NAME...]] [--list]
#   fw-harvest.sh --from-dumps DUMPDIR [--out DIR] [--only ...]   # raw .img in
#
# A source root that is not supplied is reported as SKIP (not an error) — you can
# harvest just the apnhlos blobs, or just vendor, independently.

set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MANIFEST="$SELF_DIR/fw-manifest.tsv"
OUT="$SELF_DIR/../root-build/stock-extract/harvest"
APNHLOS=""
VENDOR=""
ONLY=""
LIST=0
FROM_DUMPS=""
WORK=""

die() { echo "!! $*" >&2; exit 1; }

cleanup() { [ -n "$WORK" ] && { umount "$WORK"/mnt/* 2>/dev/null || true; rm -rf "$WORK" 2>/dev/null || true; }; }
trap cleanup EXIT

while [ $# -gt 0 ]; do
	case "$1" in
		--manifest) MANIFEST=$2; shift 2 ;;
		--apnhlos)  APNHLOS=$2; shift 2 ;;
		--vendor)   VENDOR=$2; shift 2 ;;
		--out)      OUT=$2; shift 2 ;;
		--only)     ONLY=$2; shift 2 ;;
		--from-dumps) FROM_DUMPS=$2; shift 2 ;;
		--list)     LIST=1; shift ;;
		-h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
		*) die "unknown arg: $1" ;;
	esac
done

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

# want NAME -> is it selected by --only?
selected() {
	[ -z "$ONLY" ] && return 0
	case ",$ONLY," in *",$1,"*) return 0 ;; esac
	return 1
}

# --list: print the manifest as a readable table, no harvesting.
if [ "$LIST" -eq 1 ]; then
	printf '%-12s %-8s %-6s %-8s %s\n' NAME SOURCE CLASS STATUS SRC_GLOB
	while IFS=$(printf '\t') read -r name source glob dest tier class status notes; do
		case "$name" in ''|\#*) continue ;; esac
		printf '%-12s %-8s %-6s %-8s %s\n' "$name" "$source" "$class" "$status" "$glob"
	done < "$MANIFEST"
	exit 0
fi

# --from-dumps: build apnhlos/ and vendor/ source roots from raw partition images.
if [ -n "$FROM_DUMPS" ]; then
	[ "$(id -u)" -eq 0 ] || die "--from-dumps needs root (loop mounts / lpunpack)"
	WORK=$(mktemp -d)
	mkdir -p "$WORK/mnt/apnhlos" "$WORK/mnt/vendor"
	if [ -f "$FROM_DUMPS/apnhlos.img" ]; then
		mount -o ro,loop "$FROM_DUMPS/apnhlos.img" "$WORK/mnt/apnhlos" \
			&& APNHLOS="$WORK/mnt/apnhlos" || echo "!! could not mount apnhlos.img" >&2
	fi
	if [ -f "$FROM_DUMPS/super.img" ]; then
		command -v lpunpack >/dev/null || die "lpunpack not found (android-tools / lpunpack)"
		lpunpack --partition vendor "$FROM_DUMPS/super.img" "$WORK" >/dev/null \
			|| die "lpunpack of vendor from super.img failed"
		mount -o ro,loop "$WORK/vendor.img" "$WORK/mnt/vendor" \
			&& VENDOR="$WORK/mnt/vendor" \
			|| die "could not mount vendor.img (erofs kernel support / erofs-utils needed)"
	fi
fi

mkdir -p "$OUT"

# resolve the mounted root for a given source name, or empty if not supplied
root_for() {
	case "$1" in
		apnhlos) echo "$APNHLOS" ;;
		vendor)  echo "$VENDOR" ;;
		*)       echo "" ;;
	esac
}

harvested=0 missing=0 skipped=0
printf '%-12s %-8s %s\n' NAME SOURCE RESULT
printf '%-12s %-8s %s\n' ------------ -------- ------

while IFS=$(printf '\t') read -r name source glob dest tier class status notes; do
	case "$name" in ''|\#*) continue ;; esac
	selected "$name" || continue

	root=$(root_for "$source")
	if [ -z "$root" ]; then
		printf '%-12s %-8s SKIP  (source not supplied)\n' "$name" "$source"
		skipped=$((skipped + 1))
		continue
	fi

	# expand the glob within the source root
	set +f
	# shellcheck disable=SC2086
	set -- $(cd "$root" 2>/dev/null && ls -1 $glob 2>/dev/null || true)
	set -f
	if [ "$#" -eq 0 ]; then
		printf '%-12s %-8s MISS  (%s: no match for %s)\n' "$name" "$source" "$status" "$glob"
		missing=$((missing + 1))
		continue
	fi

	destdir="$OUT/$dest"
	mkdir -p "$destdir"
	n=0
	for rel in "$@"; do
		cp -f "$root/$rel" "$destdir/$(basename "$rel")"
		n=$((n + 1))
	done
	printf '%-12s %-8s OK    (%d file(s) -> %s/)\n' "$name" "$source" "$n" "$dest"
	harvested=$((harvested + 1))
done < "$MANIFEST"

echo
echo ">> harvested $harvested, missing $missing, skipped $skipped  (staged in $OUT)"
[ "$missing" -eq 0 ] || echo ">> NOTE: MISS on a working/wip row means the build gate should fail before flashing."
