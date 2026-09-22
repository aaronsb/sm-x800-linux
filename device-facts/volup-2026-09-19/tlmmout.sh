#!/bin/sh
# tlmmout.sh <pin> <0|1>: set the TLMM GPIO_IN_OUT output bit (bit 1) of a pin already in output mode.
p=$1; v=$2; a=$((0xf100000 + p*0x1000 + 4))
cur=$(devmem2 $a w | tail -1 | awk '{print $NF}')
if [ "$v" = 1 ]; then nv=$(( cur | 2 )); else nv=$(( cur & ~2 )); fi
devmem2 $a w $nv >/dev/null
echo "tlmm$p in_out: $cur -> $(devmem2 $a w | tail -1 | awk '{print $NF}')"
