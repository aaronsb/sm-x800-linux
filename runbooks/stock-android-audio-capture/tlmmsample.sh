#!/system/bin/sh
# tlmmsample.sh DUR : sample TLMM gpio171-174 levels from debugfs for DUR seconds
D=${1:-5}; end=$(( $(date +%s) + D )); n=0
for g in 171 172 173 174; do eval "c$g=0; l$g="; done
while [ $(date +%s) -lt $end ]; do
  grep -E '^ gpio17[1-4] ' /sys/kernel/debug/gpio | while read -r name colon dir lvl rest; do echo "$name $lvl"; done > /data/local/tmp/tl.$$
  for g in 171 172 173 174; do
    v=$(grep "^gpio$g " /data/local/tmp/tl.$$ | cut -d' ' -f2)
    eval "last=\$l$g"; [ -n "$last" ] && [ "$last" != "$v" ] && eval "c$g=\$((c$g+1))"; eval "l$g=$v"
    eval "h${g}_$v=\$(( \${h${g}_$v:-0} + 1 ))"
  done
  n=$((n+1))
done
rm -f /data/local/tmp/tl.$$
for g in 171 172 173 174; do eval "echo tlmm$g: low=\${h${g}_low:-0} high=\${h${g}_high:-0} transitions=\$c$g rounds=$n"; done
