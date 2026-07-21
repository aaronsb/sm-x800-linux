#!/bin/sh
# gts8pwifi-setup — assemble the daily-driver from a minimal rootfs.
#
# EndeavourOS-style: the flashed image stays minimal; the "distribution" is
# a package selection applied on device. Alpine's native unit for that is
# the metapackage, so this is mostly one apk transaction plus the firmware
# extraction that no image or package may carry.
#
#   gts8pwifi-setup           toolkit only (device-samsung-gts8pwifi-tools)
#   gts8pwifi-setup plasma    toolkit + Plasma Desktop 6 (KWin Wayland)

set -e

if [ "$(id -u)" != 0 ]; then
	echo "run as root (sudo gts8pwifi-setup)" >&2
	exit 1
fi

echo ">> installing device toolkit metapackage"
apk add device-samsung-gts8pwifi-tools

if [ "$1" = "plasma" ]; then
	echo ">> installing Plasma Desktop (KDE 6, KWin Wayland)"
	apk add postmarketos-ui-plasma-desktop
fi

echo ">> extracting device-signed GPU firmware (zap) from apnhlos"
gts8pwifi-fw-extract

cat <<'EOF'
>> done. Remaining manual bits:
   - WiFi profile (lost with userdata):
       nmcli dev wifi connect <ssid> password <pw>
   - reboot to pick up the initramfs with GPU firmware
EOF
