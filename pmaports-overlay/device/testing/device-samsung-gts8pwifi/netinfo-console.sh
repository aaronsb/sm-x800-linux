#!/bin/sh
# Generate /etc/issue: the login banner agetty prints above "login:".
#
# HISTORY: v1 of this script watched the network and printed straight to
# /dev/console — the only way to learn the device's IP back when it had no
# input devices. With keyboard/touch working that design became pure noise:
# every async write stomped agetty's prompt and made it re-issue "login:"
# (screenshot-verified mess). v2 never touches the console. It writes
# /etc/issue ONCE; agetty re-reads the file and resolves the escapes every
# time it prints a prompt, so the network info is always current with no
# process running at all:
#
#   \4{wlan0}  current IPv4 of wlan0 (agetty resolves at print time)
#   \r \m \n \l  kernel release, arch, hostname, tty
#
# Slow-changing facts (OS name, memory) are baked at generation time.
# Press Enter at the prompt to cycle agetty and get a fresh banner.

set -e

ISSUE=${1:-/etc/issue}

os_name=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
mem_gib=$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)

# ANSI passes straight through agetty to fbcon. Banner: toilet -f pagga
# "SM-X800", one color per row for a cheap gradient (Terminus has the
# block glyphs).
ESC=$(printf '\033')
C1="$ESC[38;5;51m"	# bright cyan
C2="$ESC[38;5;45m"	# cyan-blue
C3="$ESC[38;5;39m"	# blue
DIM="$ESC[2m"
BLD="$ESC[1m"
RST="$ESC[0m"

{
	printf '\n'
	printf '%s\n' "${C1}░█▀▀░█▄█░░░░░█░█░▄▀▄░▄▀▄░▄▀▄${RST}"
	printf '%s\n' "${C2}░▀▀█░█░█░▄▄▄░▄▀▄░▄▀▄░█/█░█/█${RST}"
	printf '%s\n' "${C3}░▀▀▀░▀░▀░░░░░▀░▀░░▀░░░▀░░░▀░${RST}"
	printf '\n'
	printf '%s\n' "${BLD}Samsung Galaxy Tab S8+ (Wi-Fi)${RST} — mainline Linux"
	printf '%s\n' "${os_name:-postmarketOS} ${DIM}·${RST} kernel \\r ${DIM}·${RST} \\m"
	printf '%s\n' "8 cores ${DIM}·${RST} ${mem_gib} GiB RAM ${DIM}·${RST} Adreno 730 ${DIM}·${RST} 2800x1752 OLED @120Hz"
	printf '\n'
	printf '%s\n' "wlan0 \\4{wlan0} ${DIM}·${RST} ssh user@\\4{wlan0} ${DIM}·${RST} \\n on \\l"
	printf '\n'
} > "$ISSUE"
