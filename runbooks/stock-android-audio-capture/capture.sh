#!/usr/bin/env bash
# capture.sh: one-shot audio evidence capture from rooted stock Android on the
# Galaxy Tab S8+ (SM-X800, SM8450). Runs on the host over adb.
#
# Snapshots regulator, GPIO, pinctrl, clock, regmap, DAPM and mixer state four
# times (idle, recording, speaker playback, idle again), collects static
# inventory once, pulls everything into a timestamped directory, and prints the
# lines that changed between idle and recording / idle and playback.
#
# Usage:
#   capture.sh [--out DIR] [--serial SERIAL] [--seconds N]
#              [--record voicenote|tinycap|manual|skip]
#              [--playback view|tinyplay|manual|skip]
#              [--i2cdetect] [--no-prompt] [--keep-device-copy]
#
# Exit codes: 0 done, 1 a step failed (message on stderr), 2 bad usage.
#
# Read README.md in this directory first. The mode notes matter: tinycap and
# tinyplay talk to raw PCM devices and bypass the vendor audio HAL, so they do
# not exercise the HAL's mic power-up or amplifier bring-up. The HAL-routed
# modes (voicenote, view) need one tap on the tablet unless --no-prompt is set.

set -u -o pipefail

OUT_ROOT="./out"
SERIAL=""
SECONDS_ACTIVE=20
RECORD_MODE="voicenote"
PLAYBACK_MODE="view"
I2CDETECT=0
NO_PROMPT=0
KEEP_DEVICE_COPY=0
DEV_BASE="/data/local/tmp/audiocap"

usage() {
	sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT_ROOT=${2:?}; shift 2 ;;
		--serial) SERIAL=${2:?}; shift 2 ;;
		--seconds) SECONDS_ACTIVE=${2:?}; shift 2 ;;
		--record) RECORD_MODE=${2:?}; shift 2 ;;
		--playback) PLAYBACK_MODE=${2:?}; shift 2 ;;
		--i2cdetect) I2CDETECT=1; shift ;;
		--no-prompt) NO_PROMPT=1; shift ;;
		--keep-device-copy) KEEP_DEVICE_COPY=1; shift ;;
		-h|--help) usage ;;
		*) echo "unknown argument: $1" >&2; usage ;;
	esac
done

case "$RECORD_MODE" in voicenote|tinycap|manual|skip) ;; *) echo "bad --record: $RECORD_MODE" >&2; usage ;; esac
case "$PLAYBACK_MODE" in view|tinyplay|manual|skip) ;; *) echo "bad --playback: $PLAYBACK_MODE" >&2; usage ;; esac
case "$SECONDS_ACTIVE" in ''|*[!0-9]*) echo "bad --seconds: $SECONDS_ACTIVE" >&2; usage ;; esac
[ "$SECONDS_ACTIVE" -ge 8 ] || { echo "--seconds must be at least 8 (snapshots take a few seconds)" >&2; exit 2; }

if [ "$NO_PROMPT" -eq 1 ]; then
	[ "$RECORD_MODE" = voicenote ] && RECORD_MODE=tinycap
	[ "$PLAYBACK_MODE" = view ] && PLAYBACK_MODE=tinyplay
	[ "$RECORD_MODE" = manual ] && { echo "--record manual needs a prompt; drop --no-prompt" >&2; exit 2; }
	[ "$PLAYBACK_MODE" = manual ] && { echo "--playback manual needs a prompt; drop --no-prompt" >&2; exit 2; }
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$OUT_ROOT/$STAMP"
DEV_OUT="$DEV_BASE/out/$STAMP"
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 1; }
LOG="$OUT/capture.log"
: > "$LOG"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 1; }

ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

# ---------------------------------------------------------------------------
# Host prerequisites
# ---------------------------------------------------------------------------
for t in adb diff sed awk grep; do
	command -v "$t" >/dev/null 2>&1 || die "host tool missing: $t"
done
HAVE_PYTHON=0
command -v python3 >/dev/null 2>&1 && HAVE_PYTHON=1

log "output directory: $OUT"
log "record mode: $RECORD_MODE, playback mode: $PLAYBACK_MODE, active window: ${SECONDS_ACTIVE}s"

# ---------------------------------------------------------------------------
# Device and root shell
# ---------------------------------------------------------------------------
state=$("${ADB[@]}" get-state 2>/dev/null || true)
[ "$state" = device ] || die "adb sees no authorised device (state: '${state:-none}'). Enable USB debugging and accept the RSA prompt."

ROOT_MODE=""
if "${ADB[@]}" root >/dev/null 2>&1; then
	"${ADB[@]}" wait-for-device >/dev/null 2>&1
	sleep 2
	if [ "$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r')" = 0 ]; then
		ROOT_MODE=adbroot
	fi
fi
if [ -z "$ROOT_MODE" ]; then
	if [ "$("${ADB[@]}" shell "su -c id -u" 2>/dev/null | tr -d '\r')" = 0 ]; then
		ROOT_MODE=su
	fi
fi
[ -n "$ROOT_MODE" ] || die "no root shell: 'adb root' did not stick and 'su -c id' is not uid 0. Grant root to Shell in the KernelSU manager (docs/01 step 7)."
log "root shell via: $ROOT_MODE"

# rsh CMD: run one command line as root on the device. Arguments must not
# contain single quotes; every device-side action goes through cap.sh so the
# command lines stay simple.
rsh() {
	if [ "$ROOT_MODE" = adbroot ]; then
		"${ADB[@]}" shell "$*"
	else
		"${ADB[@]}" shell "su -c '$*'"
	fi
}
# rsh_ok CMD: like rsh but with a printed marker, because exit codes do not
# survive every su implementation.
rsh_ok() {
	local r
	r=$(rsh "$* && echo __OK__" 2>&1 | tr -d '\r')
	printf '%s\n' "$r" | grep -v '^__OK__$' >&2 || true
	printf '%s\n' "$r" | grep -q '^__OK__$'
}
cap() { rsh "sh $DEV_BASE/cap.sh $*"; }
cap_ok() { rsh_ok "sh $DEV_BASE/cap.sh $*"; }

# ---------------------------------------------------------------------------
# Device-side helper. POSIX sh for Android's mksh. Every path it probes is
# checked at runtime; a missing file is recorded, never fatal.
# ---------------------------------------------------------------------------
CAP_LOCAL=$(mktemp) || die "mktemp failed"
trap 'rm -f "$CAP_LOCAL" "${TONE_LOCAL:-}"' EXIT
cat > "$CAP_LOCAL" <<'EOF_DEV'
#!/system/bin/sh
# cap.sh: device side of capture.sh. Runs as root.
#   cap.sh prep OUTDIR
#   cap.sh static OUTDIR [i2cdetect]
#   cap.sh snap OUTDIR PHASE
#   cap.sh have TOOL
#   cap.sh pcm capture|playback         (prints first matching PCM device no.)
#   cap.sh record-start OUTDIR SECONDS   (tinycap in background)
#   cap.sh play-start FILE SECONDS       (tinyplay in background)
#   cap.sh stop                          (kill tinycap/tinyplay)
#   cap.sh finish OUTDIR                 (chmod for adb pull)
PATH=/system/bin:/system/xbin:/vendor/bin:/odm/bin:$PATH
DBG=/sys/kernel/debug
cmd=$1; shift

note() { echo "$*" >> "$OUTDIR/notes.txt"; }
save() { # save SRC DST : copy a file if readable, else note it
	if [ -r "$1" ]; then cat "$1" > "$2" 2>>"$OUTDIR/errors.txt"; else note "missing: $1"; fi
}

ensure_debugfs() {
	if [ ! -d "$DBG/regulator" ] && [ ! -d "$DBG/clk" ]; then
		mount -t debugfs none "$DBG" 2>/dev/null
	fi
	if [ ! -d "$DBG/regulator" ] && [ ! -d "$DBG/clk" ]; then
		note "debugfs not available at $DBG (mount failed or CONFIG_DEBUG_FS off); sysfs fallbacks only"
		return 1
	fi
	return 0
}

case "$cmd" in
prep)
	OUTDIR=$1
	mkdir -p "$OUTDIR" || exit 1
	: > "$OUTDIR/notes.txt"; : > "$OUTDIR/errors.txt"
	pkill tinycap 2>/dev/null; pkill tinyplay 2>/dev/null
	ensure_debugfs
	echo __OK__
	;;

have)
	command -v "$1" >/dev/null 2>&1 && echo yes || echo no
	;;

pcm)
	# /proc/asound/pcm lines look like: 00-05: MultiMedia2 (*) :  : playback 1 : capture 1
	want=$1
	grep -E ": $want" /proc/asound/pcm 2>/dev/null | head -1 | sed 's/^[0-9]*-\([0-9]*\):.*/\1/' | sed 's/^0*//; s/^$/0/'
	;;

static)
	OUTDIR=$1; I2CDET=${2:-0}
	S=$OUTDIR/static; mkdir -p "$S/vendor" "$S/i2c"
	{
		echo "date: $(date)"
		echo "uptime: $(cat /proc/uptime)"
		echo "kernel: $(cat /proc/version)"
		echo "fingerprint: $(getprop ro.build.fingerprint)"
		echo "bootloader: $(getprop ro.bootloader)"
		echo "sku: $(getprop ro.boot.product.vendor.sku)"
		echo "debugfs: $( [ -d $DBG/regulator ] && echo yes || echo no )"
		for t in tinymix tinycap tinyplay i2cdetect i2cget sha256sum pkill; do
			printf 'tool %s: %s\n' "$t" "$(command -v $t 2>/dev/null || echo missing)"
		done
	} > "$S/manifest.txt"
	dmesg > "$S/dmesg.txt" 2>>"$OUTDIR/errors.txt"
	getprop > "$S/getprop.txt" 2>>"$OUTDIR/errors.txt"
	save /proc/cmdline "$S/cmdline.txt"
	save /proc/asound/cards "$S/asound-cards.txt"
	save /proc/asound/pcm "$S/asound-pcm.txt"
	ls -l /dev/snd > "$S/dev-snd.txt" 2>&1
	ps -A > "$S/ps.txt" 2>&1
	# i2c inventory: bus number -> DT node, devices -> name/of_node
	{
		for a in /sys/class/i2c-adapter/i2c-*; do
			[ -e "$a" ] || continue
			printf '%s\t%s\t%s\n' "$(basename $a)" "$(cat $a/name 2>/dev/null)" "$(readlink -f $a/of_node 2>/dev/null | sed 's|.*/devicetree/base||')"
		done
	} > "$S/i2c/adapters.tsv"
	ls -l /sys/bus/i2c/devices > "$S/i2c/devices-ls.txt" 2>&1
	{
		for d in /sys/bus/i2c/devices/*-00*; do
			[ -e "$d" ] || continue
			printf '%s\t%s\t%s\t%s\n' "$(basename $d)" "$(cat $d/name 2>/dev/null)" "$(cat $d/modalias 2>/dev/null)" "$(readlink -f $d/of_node 2>/dev/null | sed 's|.*/devicetree/base||')"
		done
	} > "$S/i2c/devices.tsv"
	if [ "$I2CDET" = 1 ]; then
		if command -v i2cdetect >/dev/null 2>&1; then
			for dev in /dev/i2c-*; do
				n=${dev#/dev/i2c-}
				echo "== bus $n ($dev)"; i2cdetect -y -r "$n" 2>&1
			done > "$S/i2c/i2cdetect.txt"
		else
			note "i2cdetect requested but not on device"
		fi
	fi
	# regmap index (what exists, before any filtering)
	ls -1 "$DBG/regmap" > "$S/regmap-index.txt" 2>>"$OUTDIR/errors.txt"
	ls -1 "$DBG/pinctrl" > "$S/pinctrl-index.txt" 2>>"$OUTDIR/errors.txt"
	ls -1 "$DBG/regulator" > "$S/regulator-index.txt" 2>>"$OUTDIR/errors.txt"
	ls -1R "$DBG/asoc" > "$S/asoc-index.txt" 2>>"$OUTDIR/errors.txt"
	# thermal trip points (static part)
	{
		for z in /sys/class/thermal/thermal_zone*; do
			[ -e "$z" ] || continue
			printf '%s\t%s\n' "$(basename $z)" "$(cat $z/type 2>/dev/null)"
			for tp in "$z"/trip_point_*_temp; do
				[ -e "$tp" ] || continue
				i=${tp##*trip_point_}; i=${i%_temp}
				printf '\ttrip %s\t%s\t%s\n' "$i" "$(cat $tp 2>/dev/null)" "$(cat $z/trip_point_${i}_type 2>/dev/null)"
			done
		done
	} > "$S/thermal-trips.txt"
	# vendor audio configuration
	AUD=/vendor/etc/audio/sku_taro
	if [ -d "$AUD" ]; then
		ls -l "$AUD" > "$S/vendor/audio-dir-ls.txt" 2>&1
		for x in "$AUD"/*.xml; do [ -f "$x" ] && cp "$x" "$S/vendor/" 2>>"$OUTDIR/errors.txt"; done
	else
		note "missing dir: $AUD"
	fi
	for x in /vendor/etc/mixer_paths*.xml /vendor/etc/audio/*.xml /vendor/etc/audio_platform_info*.xml; do
		[ -f "$x" ] || continue
		[ -f "$S/vendor/$(basename $x)" ] || cp "$x" "$S/vendor/" 2>>"$OUTDIR/errors.txt"
	done
	ls -l /vendor/firmware/cs35l45* > "$S/vendor/cs35l45-firmware-ls.txt" 2>&1
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum /vendor/firmware/cs35l45* > "$S/vendor/cs35l45-firmware-sha256.txt" 2>&1
	else
		note "sha256sum missing; firmware hashes not taken"
	fi
	ls -lR /vendor/etc/sensors > "$S/vendor/sensors-ls.txt" 2>&1
	ls -1 /vendor/firmware > "$S/vendor/firmware-index.txt" 2>&1
	echo __OK__
	;;

snap)
	OUTDIR=$1; PHASE=$2
	P=$OUTDIR/$PHASE; mkdir -p "$P/pinctrl" "$P/regmap" "$P/regulators"
	echo "snapshot $PHASE begin $(date +%s)" >> "$OUTDIR/notes.txt"
	# regulators
	save "$DBG/regulator/regulator_summary" "$P/regulator_summary.txt"
	{
		for r in "$DBG"/regulator/*/; do
			[ -d "$r" ] || continue
			n=$(basename "$r")
			[ "$n" = regulator_summary ] && continue
			printf '== %s' "$n"
			for f in enable voltage open_count use_count bypass_count; do
				[ -r "$r/$f" ] && printf '\t%s=%s' "$f" "$(cat $r/$f 2>/dev/null)"
			done
			printf '\n'
			[ -r "$r/consumers" ] && sed 's/^/\t/' "$r/consumers"
		done
	} > "$P/regulators/debugfs-per-regulator.txt" 2>>"$OUTDIR/errors.txt"
	{
		for r in /sys/class/regulator/regulator.*; do
			[ -d "$r" ] || continue
			printf '%s\t%s\tstate=%s\tuV=%s\tusers=%s\n' "$(basename $r)" "$(cat $r/name 2>/dev/null)" \
				"$(cat $r/state 2>/dev/null)" "$(cat $r/microvolts 2>/dev/null)" "$(cat $r/num_users 2>/dev/null)"
		done
	} > "$P/regulators/sysfs-class-regulator.tsv" 2>>"$OUTDIR/errors.txt"
	grep -E 'pm8350' "$P/regulators/sysfs-class-regulator.tsv" > "$P/regulators/pm8350-ldos.tsv" 2>/dev/null
	# gpio, pinctrl
	save "$DBG/gpio" "$P/gpio.txt"
	for pc in "$DBG"/pinctrl/*/; do
		[ -d "$pc" ] || continue
		n=$(basename "$pc")
		for f in pins pinmux-pins pinconf-pins gpio-ranges pinmux-functions pingroups; do
			[ -r "$pc/$f" ] && cat "$pc/$f" > "$P/pinctrl/$n.$f.txt" 2>>"$OUTDIR/errors.txt"
		done
	done
	# clocks
	save "$DBG/clk/clk_summary" "$P/clk_summary.txt"
	# regmaps: amps, LPASS macros/codec, MAX77705 family, anything audio-looking
	for rm in "$DBG"/regmap/*/; do
		[ -d "$rm" ] || continue
		n=$(basename "$rm")
		case "$n" in
			*cs35l45*|*-0030|*-0031|*-0032|*-0033|*macro*|*lpass*|*cdc*|*bolero*|*swr*|*soundwire*|*max777*|*-0066|*-0069|*-0036|*-0025|*fuelgauge*|*charger*|*muic*|*pdic*|*ccic*)
				[ -r "$rm/registers" ] && cat "$rm/registers" > "$P/regmap/$n.registers.txt" 2>>"$OUTDIR/errors.txt"
				for f in name range access; do
					[ -r "$rm/$f" ] && cat "$rm/$f" > "$P/regmap/$n.$f.txt" 2>/dev/null
				done
				;;
		esac
	done
	# DAPM: every widget's state, plus the On subset
	if [ -d "$DBG/asoc" ]; then
		find "$DBG/asoc" -path '*/dapm/*' -type f 2>/dev/null | while read -r w; do
			printf '%s: %s\n' "${w#$DBG/asoc/}" "$(head -1 $w 2>/dev/null)"
		done > "$P/dapm-widgets.txt"
		grep ': On' "$P/dapm-widgets.txt" > "$P/dapm-on.txt" 2>/dev/null
	else
		note "no $DBG/asoc"
	fi
	# mixer and PCM state
	if command -v tinymix >/dev/null 2>&1; then
		tinymix contents > "$P/tinymix.txt" 2>/dev/null || tinymix > "$P/tinymix.txt" 2>&1
	else
		note "tinymix missing"
	fi
	{
		for s in /proc/asound/card*/pcm*/sub*/status; do
			[ -e "$s" ] || continue
			echo "== $s"; cat "$s"
			hw=${s%status}hw_params; [ -e "$hw" ] && cat "$hw"
		done
	} > "$P/pcm-status.txt" 2>>"$OUTDIR/errors.txt"
	save /proc/interrupts "$P/interrupts.txt"
	{
		for z in /sys/class/thermal/thermal_zone*; do
			[ -e "$z" ] || continue
			printf '%s\t%s\t%s\n' "$(basename $z)" "$(cat $z/type 2>/dev/null)" "$(cat $z/temp 2>/dev/null)"
		done
	} > "$P/thermal-temps.tsv"
	ps -A 2>/dev/null | grep -iE 'audio|tiny|voicenote|media' > "$P/ps-audio.txt"
	echo "snapshot $PHASE end $(date +%s)" >> "$OUTDIR/notes.txt"
	echo __OK__
	;;

record-start)
	OUTDIR=$1; SECS=$2
	command -v tinycap >/dev/null 2>&1 || { echo "tinycap missing"; exit 1; }
	dev=$(grep -E ': capture' /proc/asound/pcm 2>/dev/null | head -1 | sed 's/^[0-9]*-\([0-9]*\):.*/\1/' | sed 's/^0*//; s/^$/0/')
	[ -n "$dev" ] || { echo "no capture PCM in /proc/asound/pcm"; exit 1; }
	echo "tinycap device $dev for ${SECS}s" >> "$OUTDIR/notes.txt"
	nohup tinycap "$OUTDIR/tinycap.wav" -D 0 -d "$dev" -c 2 -r 48000 -b 16 -T "$SECS" > "$OUTDIR/tinycap.log" 2>&1 </dev/null &
	sleep 1
	pgrep tinycap >/dev/null 2>&1 && echo __OK__ || { cat "$OUTDIR/tinycap.log"; exit 1; }
	;;

play-start)
	FILE=$1; SECS=$2
	command -v tinyplay >/dev/null 2>&1 || { echo "tinyplay missing"; exit 1; }
	[ -f "$FILE" ] || { echo "no tone file $FILE"; exit 1; }
	dev=$(grep -E ': playback' /proc/asound/pcm 2>/dev/null | head -1 | sed 's/^[0-9]*-\([0-9]*\):.*/\1/' | sed 's/^0*//; s/^$/0/')
	[ -n "$dev" ] || { echo "no playback PCM in /proc/asound/pcm"; exit 1; }
	nohup tinyplay "$FILE" -D 0 -d "$dev" > "$(dirname $FILE)/tinyplay.log" 2>&1 </dev/null &
	sleep 1
	pgrep tinyplay >/dev/null 2>&1 && echo __OK__ || { cat "$(dirname $FILE)/tinyplay.log"; exit 1; }
	;;

stop)
	pkill tinycap 2>/dev/null; pkill tinyplay 2>/dev/null
	echo __OK__
	;;

finish)
	OUTDIR=$1
	chmod -R a+rX "$OUTDIR" 2>/dev/null
	echo __OK__
	;;

*)
	echo "cap.sh: unknown command $cmd"; exit 2 ;;
esac
EOF_DEV

rsh "mkdir -p $DEV_BASE" >/dev/null 2>&1
"${ADB[@]}" push "$CAP_LOCAL" "$DEV_BASE/cap.sh" >/dev/null 2>&1 || {
	# In su mode /data/local/tmp is shell-writable, so the push should work; if
	# it did not, try through /sdcard.
	"${ADB[@]}" push "$CAP_LOCAL" /sdcard/audiocap-cap.sh >/dev/null 2>&1 || die "adb push of the helper failed"
	rsh "cp /sdcard/audiocap-cap.sh $DEV_BASE/cap.sh" >/dev/null 2>&1 || die "could not place helper at $DEV_BASE/cap.sh"
}
rsh "chmod 755 $DEV_BASE/cap.sh" >/dev/null 2>&1
cap_ok prep "$DEV_OUT" || die "device prep failed (is $DEV_BASE writable as root?)"
log "device helper installed; device output dir $DEV_OUT"

dev_have() { cap have "$1" | tr -d '\r' | grep -q '^yes$'; }

# ---------------------------------------------------------------------------
# Resolve modes against what the stock image actually has
# ---------------------------------------------------------------------------
if [ "$RECORD_MODE" = tinycap ] && ! dev_have tinycap; then
	log "tinycap not on device"
	if [ "$NO_PROMPT" -eq 1 ]; then RECORD_MODE=skip; log "recording phase skipped (no tinycap, no prompt)"; else RECORD_MODE=manual; fi
fi
if [ "$PLAYBACK_MODE" = tinyplay ] && ! dev_have tinyplay; then
	log "tinyplay not on device"
	if [ "$NO_PROMPT" -eq 1 ]; then PLAYBACK_MODE=skip; log "playback phase skipped (no tinyplay, no prompt)"; else PLAYBACK_MODE=manual; fi
fi

TONE_LOCAL=""
if [ "$PLAYBACK_MODE" = tinyplay ]; then
	if [ "$HAVE_PYTHON" -eq 1 ]; then
		TONE_LOCAL=$(mktemp --suffix=.wav)
		python3 - "$TONE_LOCAL" "$SECONDS_ACTIVE" <<'EOF_PY' || die "tone generation failed"
import math, struct, sys, wave
path, secs = sys.argv[1], int(sys.argv[2])
rate, freq, amp = 48000, 440.0, 0.25
with wave.open(path, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
    frames = bytearray()
    for i in range(rate * secs):
        v = int(amp * 32767 * math.sin(2 * math.pi * freq * i / rate))
        frames += struct.pack("<hh", v, v)
    w.writeframes(bytes(frames))
EOF_PY
		"${ADB[@]}" push "$TONE_LOCAL" "$DEV_BASE/tone.wav" >/dev/null 2>&1 || die "adb push of tone.wav failed"
		log "pushed ${SECONDS_ACTIVE}s 440 Hz tone (-12 dBFS) for tinyplay"
	else
		log "python3 missing on host; cannot generate a tone"
		if [ "$NO_PROMPT" -eq 1 ]; then PLAYBACK_MODE=skip; else PLAYBACK_MODE=view; fi
		log "playback mode now: $PLAYBACK_MODE"
	fi
fi

prompt() { # prompt MESSAGE : wait for Enter unless --no-prompt
	if [ "$NO_PROMPT" -eq 1 ]; then return 0; fi
	printf '\n>>> %s\n>>> press Enter when done: ' "$*" >&2
	read -r _ </dev/tty
}

# ---------------------------------------------------------------------------
# Static inventory
# ---------------------------------------------------------------------------
log "static inventory (dmesg, getprop, i2c, thermal, vendor files)"
cap_ok static "$DEV_OUT" "$I2CDETECT" || die "static capture failed"

snap() {
	log "snapshot: $1"
	cap_ok snap "$DEV_OUT" "$1" || die "snapshot $1 failed"
}

# ---------------------------------------------------------------------------
# Phase 1: idle
# ---------------------------------------------------------------------------
snap 00-idle

# ---------------------------------------------------------------------------
# Phase 2: recording
# ---------------------------------------------------------------------------
case "$RECORD_MODE" in
	tinycap)
		log "starting tinycap for ${SECONDS_ACTIVE}s (raw PCM; bypasses the vendor HAL)"
		cap_ok record-start "$DEV_OUT" "$SECONDS_ACTIVE" || die "tinycap did not start"
		sleep 3
		snap 01-recording
		cap stop >/dev/null 2>&1
		;;
	voicenote)
		# Samsung Voice Recorder component name: not found in repo, confirm on device.
		# The generic intent below opens whatever recorder handles it.
		log "opening a recorder app (HAL-routed capture)"
		if ! rsh_ok "am start -n com.sec.android.app.voicenote/.main.VNMainActivity" 2>/dev/null; then
			rsh_ok "am start -a android.provider.MediaStore.RECORD_SOUND" >/dev/null 2>&1 || log "no recorder intent handler answered; start one by hand"
		fi
		prompt "tap Record on the tablet, keep recording until the snapshot completes"
		snap 01-recording
		prompt "stop the recording (discard it)"
		;;
	manual)
		prompt "start a microphone recording on the tablet by hand (any recorder app)"
		snap 01-recording
		prompt "stop the recording"
		;;
	skip)
		log "recording phase skipped"
		;;
esac

log "settling 5s"
sleep 5

# ---------------------------------------------------------------------------
# Phase 3: speaker playback
# ---------------------------------------------------------------------------
case "$PLAYBACK_MODE" in
	tinyplay)
		log "starting tinyplay of the tone (raw PCM; bypasses the vendor HAL)"
		cap_ok play-start "$DEV_BASE/tone.wav" "$SECONDS_ACTIVE" || die "tinyplay did not start"
		sleep 3
		snap 02-playback
		cap stop >/dev/null 2>&1
		;;
	view)
		log "opening a system sound in the default player (HAL-routed playback)"
		snd=$(rsh "ls /system/media/audio/ringtones/*.ogg /product/media/audio/ringtones/*.ogg 2>/dev/null | head -1" | tr -d '\r')
		if [ -n "$snd" ]; then
			rsh_ok "am start -a android.intent.action.VIEW -d file://$snd -t audio/ogg" >/dev/null 2>&1 || log "VIEW intent failed; play something by hand"
		else
			log "no ringtone found under /system or /product media; play something by hand"
		fi
		prompt "make sure sound is playing through the speakers (raise volume if needed), keep it playing"
		snap 02-playback
		prompt "stop playback"
		;;
	manual)
		prompt "start speaker playback on the tablet by hand"
		snap 02-playback
		prompt "stop playback"
		;;
	skip)
		log "playback phase skipped"
		;;
esac

log "settling 5s"
sleep 5

# ---------------------------------------------------------------------------
# Phase 4: idle again
# ---------------------------------------------------------------------------
snap 03-idle-after

# ---------------------------------------------------------------------------
# Pull, clean up
# ---------------------------------------------------------------------------
cap_ok finish "$DEV_OUT" || log "chmod on device output failed; pull may be partial"
log "pulling $DEV_OUT"
"${ADB[@]}" pull "$DEV_OUT" "$OUT/device" >/dev/null 2>&1 || die "adb pull failed; the data is still on the device at $DEV_OUT"
[ -d "$OUT/device" ] || die "pull produced no directory"
# adb pull may nest the stamp directory; flatten
if [ -d "$OUT/device/$STAMP" ]; then mv "$OUT/device/$STAMP"/* "$OUT/device/" && rmdir "$OUT/device/$STAMP"; fi
if [ "$KEEP_DEVICE_COPY" -eq 0 ]; then
	rsh "rm -rf $DEV_OUT $DEV_BASE/tone.wav" >/dev/null 2>&1 || log "device cleanup failed (non-fatal)"
fi
{
	echo "stamp: $STAMP"
	echo "root_mode: $ROOT_MODE"
	echo "record_mode: $RECORD_MODE"
	echo "playback_mode: $PLAYBACK_MODE"
	echo "seconds_active: $SECONDS_ACTIVE"
	echo "i2cdetect: $I2CDETECT"
	echo "host: $(uname -a)"
} > "$OUT/host-manifest.txt"

# ---------------------------------------------------------------------------
# Diffs: the headline result
# ---------------------------------------------------------------------------
D="$OUT/device"
DIFF="$OUT/diff"; mkdir -p "$DIFF"

changed_lines() { # changed_lines A B LABEL : write unified diff, print +/- lines
	local a=$1 b=$2 label=$3 out="$DIFF/$3.diff"
	if [ ! -f "$a" ] || [ ! -f "$b" ]; then
		echo "  ($label: one side missing, see device/*/notes.txt)"
		return
	fi
	diff -u "$a" "$b" > "$out" 2>/dev/null
	local n
	n=$(grep -cE '^[-+][^-+]' "$out" 2>/dev/null || true)
	echo "  $label: ${n:-0} changed lines"
	grep -E '^[-+][^-+]' "$out" | sed 's/^/    /'
}

pinctrl_concat() { # pinctrl_concat PHASE : one file with every controller's pins/pinmux/pinconf
	local p=$1 f="$D/$p/pinctrl-all.txt"
	: > "$f"
	for x in "$D/$p"/pinctrl/*.txt; do
		[ -f "$x" ] || continue
		echo "### $(basename "$x")" >> "$f"
		cat "$x" >> "$f"
	done
	echo "$f"
}

report() { # report FROM TO
	local from=$1 to=$2
	[ -d "$D/$to" ] || { echo "phase $to not captured"; return; }
	echo
	echo "== $from -> $to"
	changed_lines "$D/$from/regulator_summary.txt" "$D/$to/regulator_summary.txt" "$from-vs-$to.regulator_summary"
	changed_lines "$D/$from/regulators/sysfs-class-regulator.tsv" "$D/$to/regulators/sysfs-class-regulator.tsv" "$from-vs-$to.sysfs-regulators"
	changed_lines "$D/$from/gpio.txt" "$D/$to/gpio.txt" "$from-vs-$to.gpio"
	changed_lines "$(pinctrl_concat "$from")" "$(pinctrl_concat "$to")" "$from-vs-$to.pinctrl"
	changed_lines "$D/$from/clk_summary.txt" "$D/$to/clk_summary.txt" "$from-vs-$to.clk_summary"
	changed_lines "$D/$from/dapm-on.txt" "$D/$to/dapm-on.txt" "$from-vs-$to.dapm-on"
	for r in "$D/$from"/regmap/*.registers.txt; do
		[ -f "$r" ] || continue
		local n; n=$(basename "$r" .registers.txt)
		changed_lines "$r" "$D/$to/regmap/$n.registers.txt" "$from-vs-$to.regmap.$n"
	done
}

{
	echo "#############################################################"
	echo "# capture $STAMP: state changes (idle -> recording -> playback)"
	echo "# full diffs in $DIFF, raw snapshots in $D"
	echo "#############################################################"
	[ "$RECORD_MODE" != skip ] && report 00-idle 01-recording
	[ "$PLAYBACK_MODE" != skip ] && report 00-idle 02-playback
	report 00-idle 03-idle-after
	echo
	echo "notes from the device:"
	sed 's/^/  /' "$D/notes.txt" 2>/dev/null
	if [ -s "$D/errors.txt" ]; then echo "errors from the device:"; sed 's/^/  /' "$D/errors.txt"; fi
} | tee "$OUT/headline.txt"

log "done. results: $OUT"
exit 0
