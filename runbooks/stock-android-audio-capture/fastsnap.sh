#!/system/bin/sh
# fastsnap.sh NAME : quick state snapshot to /data/local/tmp/audiocap/hal/NAME
#
# Fast-state helper for the stock Android capture (README.md, step 5).
# Runs on the tablet as root. Reads debugfs and tinymix in a few seconds.
# It skips the CS35L45 regmaps, which are ~400 KB each over I2C and make a
# capture.sh snapshot take about five minutes. Dump an amp separately when
# the state is one you want it for:
#   cat /sys/kernel/debug/regmap/18-0030/registers > .../NAME/regmap-amps/18-0030.txt
#
# Install and run:
#   adb push fastsnap.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/fastsnap.sh 00-idle'
# then put the tablet in the next state and run it again with the next NAME.
# Pull with: adb pull /data/local/tmp/audiocap/hal ./out/hal
#
# Output per NAME: when.txt, regulator_summary.txt, gpio.txt,
# pinconf-<controller>.txt and pinmux-<controller>.txt for every pinctrl
# controller, clk_summary.txt, regmap/<audio regmap>.txt, tinymix.txt,
# interrupts.txt, ps.txt (audio, camera, media processes), err.txt.
# Prints "__OK__ NAME <files> files, <n> regmaps" on success.
#
# First used 2026-09-18. Results: device-facts/stock-runtime/2026-09-18/.
N=${1:?name}; B=/data/local/tmp/audiocap/hal; D=$B/$N; mkdir -p "$D"
mountpoint -q /sys/kernel/debug 2>/dev/null || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
date > "$D/when.txt"
cat /sys/kernel/debug/regulator/regulator_summary > "$D/regulator_summary.txt" 2>"$D/err.txt"
cat /sys/kernel/debug/gpio > "$D/gpio.txt" 2>>"$D/err.txt"
for p in /sys/kernel/debug/pinctrl/*/; do n=$(basename "$p"); cat "$p/pinconf-pins" > "$D/pinconf-$n.txt" 2>>"$D/err.txt"; cat "$p/pinmux-pins" > "$D/pinmux-$n.txt" 2>>"$D/err.txt"; done
cat /sys/kernel/debug/clk/clk_summary > "$D/clk_summary.txt" 2>>"$D/err.txt"
mkdir -p "$D/regmap"
for r in /sys/kernel/debug/regmap/*; do n=$(basename "$r"); case "$n" in *macro*|*lpass*|*cdc*|*swr*|*bolero*|*va*|*tx*|*rx*|*wsa*|*lpi*) cat "$r/registers" > "$D/regmap/$n.txt" 2>>"$D/err.txt";; esac; done
tinymix -D 0 > "$D/tinymix.txt" 2>>"$D/err.txt"
cat /proc/interrupts > "$D/interrupts.txt" 2>>"$D/err.txt"
ps -A -o PID,NAME,ARGS 2>/dev/null | grep -iE "audio|camera|media" | grep -v grep > "$D/ps.txt"
echo "__OK__ $N $(ls "$D" | wc -l) files, $(ls "$D/regmap" | wc -l) regmaps"
