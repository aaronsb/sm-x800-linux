#!/system/bin/sh
# camsnap.sh NAME : camera and flash LED facts to /data/local/tmp/audiocap/cam/NAME
#
# Companion to fastsnap.sh for the stock Android round trip. Runs on the
# tablet as root. Reads Samsung's camera sysfs (sensor ids, module ids,
# firmware strings), the LED class, the camera HAL's characteristics, the
# sensor-module blobs the HAL loads, the camera lines in dmesg and the
# remoteproc list. Everything is a read except the torch toggle, which is
# opt-in: camsnap.sh NAME torch  turns the rear torch on through Samsung's
# sysfs before the reads and off after them.
#
# Install and run:
#   adb push camsnap.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/camsnap.sh 00-idle'
#   adb shell su -c 'sh /data/local/tmp/camsnap.sh 06-torch torch'
# Pull with: adb pull /data/local/tmp/audiocap/cam ./out/cam
#
# First used 2026-09-21.
N=${1:?name}; MODE=$2; B=/data/local/tmp/audiocap/cam; D=$B/$N; mkdir -p "$D"
mountpoint -q /sys/kernel/debug 2>/dev/null || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
date > "$D/when.txt"
: > "$D/err.txt"

torch() { for f in /sys/class/camera/flash/rear_flash /sys/class/camera/flash/rear_torch_flash; do [ -e "$f" ] && echo "$1" > "$f" 2>>"$D/err.txt" && echo "$f <- $1" >> "$D/torch.txt"; done; }
[ "$MODE" = torch ] && torch 1 && sleep 1

# Samsung camera sysfs: every attribute under /sys/class/camera, one line each.
for f in /sys/class/camera/*/*; do [ -f "$f" ] && printf '%s: %s\n' "$f" "$(cat "$f" 2>>"$D/err.txt" | tr '\n' ' ')"; done > "$D/sys-class-camera.txt"
# LED class, brightness and limits.
for l in /sys/class/leds/*/; do printf '%s brightness=%s max=%s trigger=%s\n' "$(basename "$l")" "$(cat "$l/brightness" 2>/dev/null)" "$(cat "$l/max_brightness" 2>/dev/null)" "$(cat "$l/trigger" 2>/dev/null | grep -o '\[.*\]')"; done > "$D/leds.txt"
# State the flash affects.
cat /sys/kernel/debug/regulator/regulator_summary > "$D/regulator_summary.txt" 2>>"$D/err.txt"
cat /sys/kernel/debug/gpio > "$D/gpio.txt" 2>>"$D/err.txt"
# Camera HAL view.
dumpsys media.camera > "$D/dumpsys-media.camera.txt" 2>>"$D/err.txt"
# Sensor-module blobs and camera config the HAL loads.
ls -la /vendor/lib64/camera /vendor/lib/camera /vendor/etc/camera 2>>"$D/err.txt" > "$D/vendor-camera-files.txt"
ls -laR /data/vendor/camera 2>>"$D/err.txt" > "$D/data-vendor-camera.txt"
getprop | grep -i -E 'camera|cam\.|flash|sensor' > "$D/getprop-camera.txt" 2>>"$D/err.txt"
# Kernel side: probe lines, i2c devices, remoteprocs.
dmesg 2>>"$D/err.txt" | grep -i -E 'cam_|cci|eeprom|actuator|flash|led|csiphy|sensor' > "$D/dmesg-camera.txt"
for i in /sys/bus/i2c/devices/*; do printf '%s %s\n' "$(basename "$i")" "$(cat "$i/name" 2>/dev/null)"; done > "$D/i2c-devices.txt"
for r in /sys/class/remoteproc/*; do printf '%s %s %s\n' "$(basename "$r")" "$(cat "$r/name" 2>/dev/null)" "$(cat "$r/state" 2>/dev/null)"; done > "$D/remoteproc.txt"
ps -A -o PID,NAME,ARGS 2>/dev/null | grep -iE "audio|camera|media|sensor" | grep -v grep > "$D/ps.txt"

[ "$MODE" = torch ] && torch 0
echo "__OK__ $N $(ls "$D" | wc -l) files, $(wc -l < "$D/sys-class-camera.txt") camera attrs, $(wc -l < "$D/leds.txt") leds"
