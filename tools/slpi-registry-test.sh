#!/bin/sh
# slpi-registry-test.sh LOG [SECONDS] [HEXAGONRPCD]
#
# Harness for the sns_registry patches to hexagonrpcd (docs/12-sensors.md,
# pmaports-overlay/temp/hexagonrpcd/). Run on the tablet as the login user
# with passwordless sudo.
#
# It stops the packaged hexagonrpcd-sdsp.service and any stray daemon, writes
# a restart-loop wrapper to /tmp, restarts the SLPI once through remoteproc0,
# then runs the daemon under the loop for SECONDS (default 60) with its
# stdout/stderr in LOG. At the end it prints: daemon restarts, SLPI crash
# lines from dmesg since the restart, the sns_registry_get_property calls
# by name, the registry writes and renames, error lines, and the last 25
# log lines before every daemon exit.
#
# HEXAGONRPCD defaults to /usr/bin/hexagonrpcd (the installed package). For a
# tree built in place pass its binary, e.g. /home/user/hexagonrpc/build/hexagonrpcd/hexagonrpcd.
# REGISTRY overrides the served tree (default the extracted Samsung one).
#
# The loop keeps running after the report so the SLPI can be watched longer.
# To restore the packaged service:
#   sudo pkill -f rpcd-loop.sh; sudo systemctl start hexagonrpcd-sdsp

LOG=${1:?usage: slpi-registry-test.sh LOG [SECONDS] [HEXAGONRPCD]}
SECS=${2:-60}
BIN=${3:-/usr/bin/hexagonrpcd}
REGISTRY=${REGISTRY:-/usr/share/qcom/sm8450/Samsung/gts8pwifi}
LOOP=/tmp/rpcd-loop.sh
RPROC=/sys/class/remoteproc/remoteproc0

[ -x "$BIN" ] || { echo "no executable at $BIN" >&2; exit 1; }
[ "$(cat $RPROC/name)" = slpi ] || { echo "$RPROC is not the slpi" >&2; exit 1; }

command -v systemctl >/dev/null && sudo systemctl stop hexagonrpcd-sdsp 2>/dev/null
sudo pkill -x hexagonrpcd; sudo pkill -f rpcd-loop.sh; sleep 1

cat > $LOOP <<EOS
#!/bin/sh
while true; do
  echo "=== rpcd-loop: starting at uptime \$(cut -d' ' -f1 /proc/uptime)"
  $BIN -f /dev/fastrpc-sdsp -d sdsp -s -R $REGISTRY
  echo "=== rpcd-loop: exited rc=\$? at uptime \$(cut -d' ' -f1 /proc/uptime)"
  sleep 1
done
EOS
chmod +x $LOOP

sudo sh -c "echo stop > $RPROC/state"; sleep 2
sudo sh -c "echo start > $RPROC/state"; sleep 1
T0=$(cut -d" " -f1 /proc/uptime)
H0=$(sudo dmesg | grep -c 'Handover signaled'); C0=$(sudo dmesg | grep -c 'fatal error received')
echo "SLPI up at uptime $T0; handover=$H0 crashes=$C0; daemon $BIN"
sudo sh -c "nohup $LOOP > $LOG 2>&1 &"
sleep $SECS
H1=$(sudo dmesg | grep -c 'Handover signaled'); C1=$(sudo dmesg | grep -c 'fatal error received')
echo "after ${SECS}s: uptime $(cut -d" " -f1 /proc/uptime) handover=$H1 crashes=$C1 rproc=$(cat $RPROC/state)"
echo "--- daemon restarts"; grep -n "=== rpcd-loop" $LOG
echo "--- crash lines"; sudo dmesg | awk -F"[][]" -v t=$T0 '$2+0 > t' | grep -E "fatal error|crash detected|PDM" | cut -c1-260
echo "--- get_property"; grep "sns_registry_get_property(" $LOG | sort | uniq -c
echo "--- writes"; grep -c "^write(" $LOG; grep -e "^rename(" -e ", [wa]) ->" $LOG | head
echo "--- errors"; grep -i -E "Could not|Unsupported|Expected|Refusing|Handles|Tried|unknown property" $LOG | sort | uniq -c | head
echo "--- last 25 lines before each exit"; awk '/=== rpcd-loop: exited/{for(i=NR-25;i<NR;i++) if(i>0) print buf[i%40]; print} {buf[NR%40]=$0}' $LOG | cut -c1-150 | head -60
echo "loop still running under $LOG; restore with: sudo pkill -f rpcd-loop.sh; sudo systemctl start hexagonrpcd-sdsp"
