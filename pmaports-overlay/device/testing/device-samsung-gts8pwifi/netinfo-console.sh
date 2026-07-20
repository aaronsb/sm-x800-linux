#!/bin/sh
# Bring-up debug aid: print network state to the framebuffer console.
#
# This device currently has no usable input, so the panel is the only way to
# learn what address it got. Watch for changes and print a compact block
# straight to /dev/console whenever anything moves.
#
# Remove this once ssh/serial access is reliable — it is a bring-up crutch,
# not something that belongs on a finished system.

CONSOLE=/dev/console
prev=""

# quick banner so we can tell the service actually started
{
	echo ""
	echo "=== netinfo: watching for addresses (bring-up debug) ==="
} > "$CONSOLE" 2>/dev/null

while :; do
	cur=$(ip -o addr show scope global 2>/dev/null | awk '{print $2, $4}')

	if [ "$cur" != "$prev" ]; then
		{
			echo ""
			echo "======== NETINFO $(date '+%H:%M:%S') ========"
			if [ -z "$cur" ]; then
				echo "  no global addresses yet"
			fi
			# one block per interface that is not loopback
			for ifc in $(ls /sys/class/net 2>/dev/null); do
				[ "$ifc" = "lo" ] && continue
				mac=$(cat "/sys/class/net/$ifc/address" 2>/dev/null)
				oper=$(cat "/sys/class/net/$ifc/operstate" 2>/dev/null)
				carrier=$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null)
				addrs=$(ip -o -4 addr show dev "$ifc" 2>/dev/null | awk '{print $4}')
				gw=$(ip -4 route show default dev "$ifc" 2>/dev/null | awk '{print $3}')
				echo "  iface : $ifc"
				echo "    mac     : $mac"
				echo "    state   : $oper (carrier=${carrier:-?})"
				if [ -n "$addrs" ]; then
					for a in $addrs; do echo "    ipv4    : $a"; done
					[ -n "$gw" ] && echo "    gateway : $gw"
					echo "    >>> ssh user@${addrs%%/*}"
				else
					echo "    ipv4    : (none - no lease)"
				fi
			done
			echo "=========================================="
		} > "$CONSOLE" 2>/dev/null
		prev="$cur"
	fi
	sleep 3
done
