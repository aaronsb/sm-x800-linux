#!/bin/sh
# gts8pwifi-bt-addr: give hci0 its public Bluetooth address.
#
# The WCN6855 on uart20 completes QCA firmware setup and then sits there
# unconfigured: `btmgmt info` lists no controller, bluetoothd reports "No
# default controller available", and /sys/kernel/debug/bluetooth/hci0 holds
# only the QCA `ibs` entry. Nothing supplies the controller's address. The DT
# `bluetooth` node has no `local-bd-address` and the bootloader fills none
# (nothing in /proc/cmdline or the chosen node). hci_qca flags the address
# invalid and the core leaves the controller unconfigured until userspace
# sets one over the management interface.
#
# The factory address lives on the `efs` partition (ext4) in
# bluetooth/bt_addr, as two addresses back to back with no separator:
# "0C:02:BD:42:8A:01" then "0C:02:BD:42:8A:02". The first 17 characters are
# the Bluetooth address. If efs or the file is missing, fall back to a
# locally administered address (02:xx:xx:xx:xx:xx) derived from
# /etc/machine-id so the controller still comes up, stable across boots.
#
# Pulled in by 90-gts8pwifi-bt-addr.rules when hci0 appears. The add event
# fires before firmware setup finishes and the management interface answers
# "Invalid Index" until it has, so the set is retried for a while.
#
# Idempotent: exits 0 without touching anything if hci0 already has an
# address. POSIX sh (busybox ash).

set -u

TAG=gts8pwifi-bt-addr
HCI=${HCI_INDEX:-0}
EFS_DEV=/dev/disk/by-partlabel/efs
MNT=/run/$TAG/efs
ADDR_RE='^[0-9A-Fa-f]\{2\}\(:[0-9A-Fa-f]\{2\}\)\{5\}$'
RETRIES=30

log() {
	logger -t "$TAG" "$*" 2>/dev/null || echo "$TAG: $*" >&2
}

die() {
	log "$*"
	exit 1
}

mounted() {
	grep -qs " $MNT " /proc/mounts
}

cleanup() {
	if mounted; then
		umount "$MNT" 2>/dev/null || log "warning: umount $MNT failed"
	fi
}
trap cleanup EXIT

# Already configured? `btmgmt info` prints an "addr" line only for a
# configured controller (an unconfigured one answers Invalid Index).
current=$(btmgmt -i "$HCI" info 2>/dev/null \
	| sed -n 's/^[[:space:]]*addr \([0-9A-Fa-f:]\{17\}\).*/\1/p' | head -n 1)
if [ -n "$current" ] && [ "$current" != "00:00:00:00:00:00" ]; then
	log "hci$HCI already configured with $current, nothing to do"
	exit 0
fi

# 1. Factory address from efs.
addr=
source=
if [ -e "$EFS_DEV" ]; then
	mkdir -p "$MNT"
	if mounted || mount -o ro "$EFS_DEV" "$MNT" 2>/dev/null; then
		if [ -r "$MNT/bluetooth/bt_addr" ]; then
			candidate=$(head -c 17 "$MNT/bluetooth/bt_addr" 2>/dev/null)
			if printf '%s\n' "$candidate" | grep -q "$ADDR_RE"; then
				addr=$candidate
				source="efs bluetooth/bt_addr"
			else
				log "efs bluetooth/bt_addr does not start with an address, ignoring"
			fi
		else
			log "efs has no bluetooth/bt_addr"
		fi
		cleanup
	else
		log "could not mount $EFS_DEV read-only"
	fi
else
	log "no efs partition at $EFS_DEV"
fi

# 2. Fallback: locally administered address from the machine id.
if [ -z "$addr" ]; then
	id=$(tr -cd '0-9a-fA-F' < /etc/machine-id 2>/dev/null | head -c 10)
	[ ${#id} -eq 10 ] || die "no usable address: efs unavailable and /etc/machine-id unreadable"
	addr="02:$(printf '%s' "$id" | sed 's/\(..\)/\1:/g; s/:$//')"
	source="machine-id fallback"
fi

printf '%s\n' "$addr" | grep -q "$ADDR_RE" \
	|| die "internal error: derived address '$addr' is malformed"

# 3. Hand it to the kernel. Retry while the controller is still in setup.
n=0
while :; do
	if out=$(btmgmt -i "$HCI" public-addr "$addr" 2>&1); then
		log "hci$HCI public address set to $addr ($source)"
		exit 0
	fi
	n=$((n + 1))
	if [ "$n" -ge "$RETRIES" ]; then
		die "failed to set hci$HCI public address $addr ($source) after $n attempts: $(printf '%s' "$out" | tail -n 1)"
	fi
	sleep 1
done
