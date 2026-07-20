#!/bin/sh
# Hammer the pogo STM32 addresses continuously to catch a brief live window.
# Run as root ON DEVICE.
#
# THEORY UNDER TEST (user's): the MCU is not dead and not merely browning out --
# it is RESTARTING in a loop, waiting for the host to hand it something, timing
# out, and resetting. Evidence: conn-detect toggles as a steady ~95ms METRONOME
# (51 edges/5s), and a metronome implies a watchdog/retry timer rather than the
# randomness you would expect from a brownout.
#
# If the MCU's i2c slave is alive for only part of each ~95ms cycle, a one-shot
# i2cdetect sweep can easily miss it -- but thousands of back-to-back attempts
# cannot. Any single ACK falsifies "nothing is on the bus" and tells us the MCU
# is reachable in a narrow window.
#
# Confirmed already: the line is genuinely DRIVEN, not floating (51 edges under
# BOTH pull-up and pull-down bias, so it overpowers either internal pull).

BUS=0
SECS=${1:-20}

echo "=== hammering 0x2a and 0x51 for ${SECS}s ==="
echo "    (any single ACK is a major result)"

end=$(( $(cut -d. -f1 /proc/uptime) + SECS ))
tries=0; hits=0
while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
	for a in 0x2a 0x51; do
		tries=$((tries+1))
		if out=$(i2cget -y -f "$BUS" "$a" 0x00 b 2>/dev/null); then
			hits=$((hits+1))
			echo "  ** HIT on $a -> $out (attempt $tries) **"
		fi
	done
done
echo "  attempts: $tries   hits: $hits"

echo
echo "=== raw read (no register write) hammer, 200 tries each ==="
# A device that NACKs a register-write may still ACK a plain address+read.
for a in 0x2a 0x51; do
	h=0; i=0
	while [ $i -lt 200 ]; do
		i2ctransfer -y -f "$BUS" "r1@$a" >/dev/null 2>&1 && h=$((h+1))
		i=$((i+1))
	done
	echo "  $a: $h/200 ACKed"
done

echo
echo "=== does bus traffic perturb the oscillation? ==="
# If the MCU is waiting for the host, hammering it might change its cadence.
EV=/dev/input/event2
before=$(timeout 5 evtest "$EV" 2>/dev/null | grep -c SW_DOCK)
echo "  edges in 5s, quiet bus:      $before"
( end2=$(( $(cut -d. -f1 /proc/uptime) + 6 ))
  while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end2" ]; do
	i2cget -y -f "$BUS" 0x2a 0x00 b >/dev/null 2>&1
  done ) &
HP=$!
during=$(timeout 5 evtest "$EV" 2>/dev/null | grep -c SW_DOCK)
wait $HP 2>/dev/null
echo "  edges in 5s, while hammered: $during"
echo "  (a change means the MCU notices us -- that would be a real handshake clue)"
echo "=== done ==="
