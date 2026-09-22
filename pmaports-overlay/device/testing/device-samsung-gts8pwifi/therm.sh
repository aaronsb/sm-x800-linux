#!/bin/sh
# gts8pwifi-therm: read the AP and Wi-Fi thermistors and print each one
# both as mainline converts it and as stock converted it.
#
# Mainline (drivers/iio/adc/qcom-vadc-common.c, qcom_vadc7_scale_hw_calib_therm)
# treats both channels as a 100k NTC against a 100k pull-up: resistance =
# code * 100000 / (16384 - code), then the generic NTCG104EF104 table
# adcmap7_100k gives the temperature. Stock instead reads the channel as
# microvolts with the ADC's default scale, code * 1875000 / 0x70e4, and
# maps them through a per-thermistor table in the device tree
# (sec_thermistor@0 "sec-ap-thermistor" and @1 "sec-wf-thermistor",
# adc_array in microvolts against temp_array in tenths of a degree C).
#
# This tool inverts mainline's conversion back to the ADC code and applies
# stock's table.
#
#   gts8pwifi-therm                  both channels: label, mainline C, stock-table C
#   gts8pwifi-therm --json           same as a JSON object
#   gts8pwifi-therm --convert LABEL MDEGC
#                                    convert one mainline reading (millidegrees,
#                                    LABEL ap_therm or wf_therm) without sysfs
#
# Tables embedded below are ADC calibration numbers: adcmap7_100k from the
# Linux kernel (GPL-2.0, drivers/iio/adc/qcom-vadc-common.c), the two stock
# tables from the tablet's stock device tree (stock-fdt.dts, sec_thermistor
# nodes), both decoded to decimal.

set -e

# adcmap7_100k from drivers/iio/adc/qcom-vadc-common.c: "ohm:millidegC"
# pairs, resistance descending, 168 entries.
KERNEL_TABLE="
4250657:-40960 3962085:-39936 3694875:-38912 3447322:-37888 3217867:-36864 3005082:-35840
2807660:-34816 2624405:-33792 2454218:-32768 2296094:-31744 2149108:-30720 2012414:-29696
1885232:-28672 1766846:-27648 1656598:-26624 1553884:-25600 1458147:-24576 1368873:-23552
1285590:-22528 1207863:-21504 1135290:-20480 1067501:-19456 1004155:-18432 944935:-17408
889550:-16384 837731:-15360 789229:-14336 743813:-13312 701271:-12288 661405:-11264
624032:-10240 588982:-9216 556100:-8192 525239:-7168 496264:-6144 469050:-5120
443480:-4096 419448:-3072 396851:-2048 375597:-1024 355598:0 336775:1024
319052:2048 302359:3072 286630:4096 271806:5120 257829:6144 244646:7168
232209:8192 220471:9216 209390:10240 198926:11264 189040:12288 179698:13312
170868:14336 162519:15360 154622:16384 147150:17408 140079:18432 133385:19456
127046:20480 121042:21504 115352:22528 109960:23552 104848:24576 100000:25600
95402:26624 91038:27648 86897:28672 82965:29696 79232:30720 75686:31744
72316:32768 69114:33792 66070:34816 63176:35840 60423:36864 57804:37888
55312:38912 52940:39936 50681:40960 48531:41984 46482:43008 44530:44032
42670:45056 40897:46080 39207:47104 37595:48128 36057:49152 34590:50176
33190:51200 31853:52224 30577:53248 29358:54272 28194:55296 27082:56320
26020:57344 25004:58368 24033:59392 23104:60416 22216:61440 21367:62464
20554:63488 19776:64512 19031:65536 18318:66560 17636:67584 16982:68608
16355:69632 15755:70656 15180:71680 14628:72704 14099:73728 13592:74752
13106:75776 12640:76800 12192:77824 11762:78848 11350:79872 10954:80896
10574:81920 10209:82944 9858:83968 9521:84992 9197:86016 8886:87040
8587:88064 8299:89088 8023:90112 7757:91136 7501:92160 7254:93184
7017:94208 6789:95232 6570:96256 6358:97280 6155:98304 5959:99328
5770:100352 5588:101376 5412:102400 5243:103424 5080:104448 4923:105472
4771:106496 4625:107520 4484:108544 4348:109568 4217:110592 4090:111616
3968:112640 3850:113664 3736:114688 3626:115712 3519:116736 3417:117760
3317:118784 3221:119808 3129:120832 3039:121856 2952:122880 2868:123904
2787:124928 2709:125952 2633:126976 2560:128000 2489:129024 2420:130048
"

usage() {
	echo "usage: gts8pwifi-therm [--json] | --convert ap_therm|wf_therm MDEGC" >&2
	exit 1
}

# Everything numeric lives in awk. $1 = label, $2 = mainline millidegrees.
# Prints "mainline_C stock_C code microvolts".
convert() {
	awk -v label="$1" -v mdeg="$2" -v ktable="$KERNEL_TABLE" '
	function interp(x0, y0, x1, y1, x) { return y0 + (y1 - y0) * (x - x0) / (x1 - x0) }

	# adcmap7_100k: resistance in ohm -> temperature in millidegrees C.
	# Resistance descends, temperature ascends, 168 entries.
	function load_kernel(s, n, i, kv) {
		n = split(s, kv, " ")
		for (i = 1; i <= n; i++) {
			split(kv[i], p, ":")
			KR[i] = p[1] + 0; KT[i] = p[2] + 0
		}
		return n
	}

	# millidegrees -> resistance: inverse of qcom_vadc_map_voltage_temp.
	function temp_to_res(t, n, i) {
		if (t <= KT[1]) return KR[1]
		if (t >= KT[n]) return KR[n]
		for (i = 2; i <= n; i++)
			if (KT[i] >= t) return interp(KT[i-1], KR[i-1], KT[i], KR[i], t)
		return KR[n]
	}

	# stock table: microvolts ascending, tenths of a degree descending.
	function load_stock(sa, st, n, i, a, t) {
		n = split(sa, a, " "); split(st, t, " ")
		for (i = 1; i <= n; i++) { SA[i] = a[i] + 0; ST[i] = t[i] + 0 }
		return n
	}

	function uv_to_stock(uv, n, i) {
		if (uv <= SA[1]) return ST[1] / 10
		if (uv >= SA[n]) return ST[n] / 10
		for (i = 2; i <= n; i++)
			if (SA[i] >= uv) return interp(SA[i-1], ST[i-1], SA[i], ST[i], uv) / 10
		return ST[n] / 10
	}

	BEGIN {
		nk = load_kernel(ktable)

		# stock-fdt.dts sec_thermistor@0, sec-ap-thermistor, ADC channel 0x144
		ap_adc = "47368 57262 70737 90609 105966 127500 152536 183062 216410 256608 301498 352980 407296 467536 530878 595445 660181 721518 779273 827264 874009 914746 949152"
		# stock-fdt.dts sec_thermistor@1, sec-wf-thermistor, ADC channel 0x14a
		wf_adc = "71509 83681 98564 116607 136907 161003 189375 222417 260378 303620 352363 406096 464415 526057 589405 653090 714868 772986 826427 873490 913897 948075 975752"
		# temp_array, shared by both nodes: 90.0 C down to -20.0 C in 5 C steps
		temps = "900 850 800 750 700 650 600 550 500 450 400 350 300 250 200 150 100 50 0 -50 -100 -150 -200"

		if (label == "ap_therm") ns = load_stock(ap_adc, temps)
		else if (label == "wf_therm") ns = load_stock(wf_adc, temps)

		r = temp_to_res(mdeg + 0, nk)
		code = r * 16384 / (r + 100000)
		uv = code * 1875000 / 28900
		printf "%.1f %.1f %d %d\n", mdeg / 1000, uv_to_stock(uv, ns), code + 0.5, uv + 0.5
	}'
}

# Find the IIO channel by its _label file and print the path of its _input.
find_channel() {
	for l in /sys/bus/iio/devices/iio:device*/in_temp_*_label; do
		[ -f "$l" ] || continue
		if [ "$(cat "$l")" = "$1" ]; then
			d=${l%/*}
			a=${l##*/}
			echo "$d/${a%_label}_input"
			return 0
		fi
	done
	return 1
}

json=
case "$1" in
--convert)
	[ $# -eq 3 ] || usage
	label=$2
	case "$label" in ap_therm|wf_therm) ;; *) usage ;; esac
	set -- $(convert "$label" "$3")
	echo "$label: mainline $1 C, stock table $2 C (code $3, $4 uV)"
	exit 0
	;;
--json) json=1 ;;
"") ;;
*) usage ;;
esac

ap=$(find_channel ap_therm) || { echo "!! no IIO channel labelled ap_therm" >&2; exit 1; }
wf=$(find_channel wf_therm) || { echo "!! no IIO channel labelled wf_therm" >&2; exit 1; }

[ -n "$json" ] && printf '{'
first=1
for label in ap_therm wf_therm; do
	case $label in ap_therm) path=$ap ;; *) path=$wf ;; esac
	mdeg=$(cat "$path")
	set -- $(convert "$label" "$mdeg")
	if [ -n "$json" ]; then
		[ -n "$first" ] || printf ','
		printf '"%s":{"mainline_c":%s,"stock_c":%s,"code":%s,"microvolts":%s}' \
			"$label" "$1" "$2" "$3" "$4"
	else
		printf '%-9s mainline %6s C   stock table %6s C\n' "$label" "$1" "$2"
	fi
	first=
done
[ -n "$json" ] && printf '}\n'
exit 0
