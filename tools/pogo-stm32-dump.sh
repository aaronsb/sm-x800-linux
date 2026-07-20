#!/bin/sh
# Dump a larger slice of the keyboard MCU's application flash and look for
# recognisable content. Run as root ON DEVICE, keyboard ATTACHED.
# READ ONLY.
CHIP=gpiochip3; NRST=97; BOOT0=99; BUS=0
FIFO=/tmp/pogo-gpio.fifo; PY=/tmp/stm32boot.py
OUT=/tmp/stm32-flash.bin
cleanup(){ [ -n "$GP" ] && kill "$GP" 2>/dev/null; exec 3>&- 2>/dev/null; rm -f "$FIFO"; }
trap cleanup EXIT INT TERM
for p in $(pgrep -x gpioset 2>/dev/null); do kill "$p" 2>/dev/null; done
sleep 1
rm -f "$FIFO"; mkfifo "$FIFO" || exit 1
gpioset -c "$CHIP" -i "$NRST=1" "$BOOT0=0" < "$FIFO" >/dev/null 2>&1 & GP=$!
exec 3> "$FIFO"; sleep 1
pulse(){ echo "set $NRST=0" >&3; echo "set $BOOT0=1" >&3; usleep 3000
         echo "set $NRST=1" >&3; usleep 50000; }
: > "$OUT"
echo "=== dumping 8 KiB of app flash, 256 bytes per pulse ==="
i=0; ok=0
while [ $i -lt 32 ]; do
  addr=$((0x08000000 + i*256))
  pulse
  if python3 "$PY" "$BUS" readraw "$addr" 256 >> "$OUT" 2>/dev/null; then
    ok=$((ok+1))
  else
    printf "  chunk %d @0x%08x FAILED\n" "$i" "$addr"
  fi
  i=$((i+1))
done
echo "  chunks ok: $ok/32  size: $(wc -c < "$OUT") bytes"
echo
echo "=== printable strings in the dump ==="
strings -n 5 "$OUT" 2>/dev/null | head -30 || echo "  (no strings tool)"
echo
echo "=== entropy check: byte-value spread ==="
od -An -tu1 -v "$OUT" 2>/dev/null | tr ' ' '\n' | grep -c . 
echo "  distinct byte values: $(od -An -tu1 -v "$OUT" | tr ' ' '\n' | grep . | sort -u | wc -l) / 256"
echo "  0xff bytes: $(od -An -tu1 -v "$OUT" | tr ' ' '\n' | grep -c '^255$')"
echo "=== restoring ==="
echo "set $BOOT0=0" >&3; echo "set $NRST=0" >&3; usleep 3000; echo "set $NRST=1" >&3
sleep 1; echo "=== done ==="
