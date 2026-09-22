// SPDX-License-Identifier: GPL-2.0-only
/*
 * Host harness for uniLoader's DTB patching path.
 *
 * Runs the sequence main/boot-fdt.c performs on the tablet, against
 * uniLoader's own libfdt, string routines and arch/aarch64/memcpy.S:
 *
 *   1. fdt_open_into(blob/dtb, fdt_buf, CONFIG_FDT_BUF_SIZE)
 *   2. fdt_setprop_u64 linux,initrd-start / linux,initrd-end
 *   3. memcpy(str, blob/cmdline, cmdline_size); fdt_setprop_string bootargs
 *   4. overlap tests against the asm memmove
 *
 * After each step the buffer is compared node by node and property by
 * property with the original blob, allowing only the expected changes.
 * The platform layer (plat_linux / plat_virt) supplies output and exit.
 */
#include <libfdt.h>
#include <string.h>

#include "plat.h"

#ifndef FDT_BUF_SIZE
#define FDT_BUF_SIZE 500000
#endif
#ifndef RAMDISK_ENTRY
#define RAMDISK_ENTRY 0xb6915000UL
#endif
#ifndef RAMDISK_SIZE
#error RAMDISK_SIZE must be defined (size of blob/ramdisk in bytes)
#endif
#define CMDLINE_MAX 2048
#define TAGALIGN(x) (((x) + 3) & ~3UL)

extern const unsigned char blob_dtb[], blob_dtb_end[];
extern const unsigned char blob_cmdline[], blob_cmdline_end[];

/* The same objects uniLoader has: static char arrays in .bss */
static char fdt_buf[FDT_BUF_SIZE];
static char str[CMDLINE_MAX];

static int failures;

/*
 * The harness's own copies go through this byte loop so that the only
 * asm memcpy/memmove calls in the run are the ones uniLoader itself makes.
 */
static void hcopy(void *dst, const void *src, unsigned long n)
{
	char *d = dst;
	const char *s = src;

	while (n--)
		*d++ = *s++;
}

/* ---- output helpers ---------------------------------------------------- */

static void out(const char *s) { plat_puts(s); }

static void out_hex(unsigned long v)
{
	char b[19];
	int i;

	b[0] = '0'; b[1] = 'x';
	for (i = 0; i < 16; i++)
		b[2 + i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 0xf];
	b[18] = 0;
	out(b);
}

static void out_dec(long v)
{
	char b[24];
	int i = 23;
	unsigned long u = v < 0 ? -(unsigned long)v : (unsigned long)v;

	b[i] = 0;
	do { b[--i] = '0' + u % 10; u /= 10; } while (u);
	if (v < 0) b[--i] = '-';
	out(b + i);
}

static void report(const char *what, int ret)
{
	out("  ");
	out(what);
	out(": ");
	out_dec(ret);
	if (ret < 0) {
		out(" (");
		out(fdt_strerror(ret));
		out(")");
		failures++;
	}
	out("\n");
}

static void check(const char *what, int ok)
{
	out("  ");
	out(what);
	out(ok ? ": ok\n" : ": FAIL\n");
	if (!ok)
		failures++;
}

/* FNV-1a over the used part of the buffer, to compare runs */
static unsigned long fnv1a(const void *p, unsigned long n)
{
	const unsigned char *b = p;
	unsigned long h = 0xcbf29ce484222325UL;

	while (n--)
		h = (h ^ *b++) * 0x100000001b3UL;
	return h;
}

/* ---- tree comparison --------------------------------------------------- */

struct expect {
	const char *path;
	const char *name;
	const void *val;
	int len;
};

static struct expect expects[4];
static int n_expects;

static void expect_prop(const char *path, const char *name, const void *val, int len)
{
	int i;

	for (i = 0; i < n_expects; i++)
		if (!strcmp(expects[i].path, path) && !strcmp(expects[i].name, name)) {
			expects[i].val = val;
			expects[i].len = len;
			return;
		}
	expects[n_expects].path = path;
	expects[n_expects].name = name;
	expects[n_expects].val = val;
	expects[n_expects].len = len;
	n_expects++;
}

static const struct expect *find_expect(const char *path, const char *name)
{
	int i;

	for (i = 0; i < n_expects; i++)
		if (!strcmp(expects[i].path, path) && !strcmp(expects[i].name, name))
			return &expects[i];
	return NULL;
}

static int count_props(const void *fdt, int node)
{
	int p, n = 0;

	fdt_for_each_property_offset(p, fdt, node)
		n++;
	return n;
}

static int count_nodes(const void *fdt)
{
	int cur, depth = -1, n = 0;

	for (cur = fdt_next_node(fdt, -1, &depth); cur >= 0 && depth >= 0;
	     cur = fdt_next_node(fdt, cur, &depth))
		n++;
	return n;
}

/*
 * Compare every node and property of `a` (the original) with `b`, allowing
 * only the registered expectations to differ or to be new in `b`.
 * Returns the number of mismatches.
 */
static int compare_trees(const void *a, const void *b)
{
	static char path[512];
	static int path_len_at[32];
	int cur, depth = -1, mismatches = 0, nodes_a = 0;

	for (cur = fdt_next_node(a, -1, &depth); cur >= 0 && depth >= 0;
	     cur = fdt_next_node(a, cur, &depth)) {
		int off_b, p, extra = 0, i;
		const char *name;
		int nl, base;

		nodes_a++;
		if (depth >= 32) {
			out("    tree too deep\n");
			mismatches++;
			break;
		}
		/* path of this node: parent's path plus "/name" */
		base = depth ? path_len_at[depth - 1] : 0;
		name = fdt_get_name(a, cur, &nl);
		if (!name || base + 1 + nl + 1 > (int)sizeof(path)) {
			out("    path build failed\n");
			mismatches++;
			continue;
		}
		if (depth == 0) {
			path[0] = '/'; path[1] = 0;
			path_len_at[0] = 0;
		} else {
			path[base] = '/';
			hcopy(path + base + 1, name, nl);
			path[base + 1 + nl] = 0;
			path_len_at[depth] = base + 1 + nl;
		}
		off_b = fdt_path_offset(b, path);
		if (off_b < 0) {
			out("    missing node "); out(path); out("\n");
			mismatches++;
			continue;
		}
		fdt_for_each_property_offset(p, a, cur) {
			const struct fdt_property *pa;
			const char *name, *pb;
			const struct expect *e;
			int la, lb;

			pa = fdt_get_property_by_offset(a, p, &la);
			name = fdt_get_string(a, fdt32_ld(&pa->nameoff), NULL);
			pb = fdt_getprop(b, off_b, name, &lb);
			if (!pb) {
				out("    missing prop "); out(path); out(":"); out(name); out("\n");
				mismatches++;
				continue;
			}
			e = find_expect(path, name);
			if (e) {
				if (lb != e->len || memcmp(pb, e->val, lb)) {
					out("    unexpected value "); out(path); out(":"); out(name);
					out(" len "); out_dec(lb); out(" want "); out_dec(e->len); out("\n");
					mismatches++;
				}
			} else if (lb != la || memcmp(pb, pa->data, la)) {
				out("    changed prop "); out(path); out(":"); out(name);
				out(" len "); out_dec(lb); out(" was "); out_dec(la); out("\n");
				mismatches++;
			}
		}
		/* properties new in b must all be expected ones */
		for (i = 0; i < n_expects; i++)
			if (!strcmp(expects[i].path, path) &&
			    !fdt_getprop(a, cur, expects[i].name, NULL)) {
				int lb;
				const void *pb = fdt_getprop(b, off_b, expects[i].name, &lb);

				if (!pb) {
					out("    expected new prop missing "); out(path); out(":");
					out(expects[i].name); out("\n");
					mismatches++;
				} else if (lb != expects[i].len || memcmp(pb, expects[i].val, lb)) {
					out("    new prop wrong value "); out(path); out(":");
					out(expects[i].name); out("\n");
					mismatches++;
				}
				extra++;
			}
		if (count_props(b, off_b) != count_props(a, cur) + extra) {
			out("    property count differs at "); out(path); out("\n");
			mismatches++;
		}
	}
	if (count_nodes(b) != nodes_a) {
		out("    node count differs\n");
		mismatches++;
	}
	return mismatches;
}

/* ---- memmove overlap tests (hypothesis 1) ------------------------------ */

static unsigned char ovl_a[8192], ovl_b[8192];

static int overlap_case(long delta, unsigned long n, unsigned long base)
{
	unsigned long i;

	for (i = 0; i < sizeof(ovl_a); i++)
		ovl_a[i] = ovl_b[i] = (unsigned char)(i * 7 + 3);
	/* reference: naive overlap-safe byte copy */
	if (delta > 0)
		for (i = n; i > 0; i--)
			ovl_b[base + delta + i - 1] = ovl_b[base + i - 1];
	else
		for (i = 0; i < n; i++)
			ovl_b[base + delta + i] = ovl_b[base + i];
	memmove(ovl_a + base + delta, ovl_a + base, n);
	return memcmp(ovl_a, ovl_b, sizeof(ovl_a)) == 0;
}

/* ---- main -------------------------------------------------------------- */

int main(void)
{
	static fdt64_t initrd_start, initrd_end;
	int ret, chosen, len, old_len, mism;
	unsigned long cmdline_size = blob_cmdline_end - blob_cmdline;
	unsigned long dtb_size = blob_dtb_end - blob_dtb;
	const char *old_bootargs;
	const char *got;
	unsigned long splice_bytes;

	plat_banner();
	out("uniLoader DTB patch harness (");
	out(HARNESS_VARIANT);
	out(")\n");
	out("  dtb "); out_dec(dtb_size); out(" bytes at "); out_hex((unsigned long)blob_dtb);
	out(", cmdline "); out_dec(cmdline_size); out(" bytes at "); out_hex((unsigned long)blob_cmdline);
	out("\n  fdt_buf "); out_dec(FDT_BUF_SIZE); out(" bytes at "); out_hex((unsigned long)fdt_buf);
	out(", str at "); out_hex((unsigned long)str); out("\n");

	/* step 1: ramdisk handler, first half */
	out("step 1: fdt_open_into\n");
	ret = fdt_open_into(blob_dtb, fdt_buf, FDT_BUF_SIZE);
	report("fdt_open_into", ret);
	if (ret < 0)
		goto done;
	report("fdt_check_header", fdt_check_header(fdt_buf));
	mism = compare_trees(blob_dtb, fdt_buf);
	check("tree identical to blob", mism == 0);

	chosen = fdt_path_offset(fdt_buf, "/chosen");
	report("fdt_path_offset /chosen", chosen);
	if (chosen < 0)
		goto done;
	old_bootargs = fdt_getprop(fdt_buf, chosen, "bootargs", &old_len);
	out("  existing bootargs len "); out_dec(old_bootargs ? old_len : -1); out("\n");

	/* step 2: ramdisk handler, initrd properties */
	out("step 2: fdt_setprop_u64 linux,initrd-start/end\n");
	initrd_start = cpu_to_fdt64(RAMDISK_ENTRY);
	initrd_end = cpu_to_fdt64(RAMDISK_ENTRY + RAMDISK_SIZE);
	ret = fdt_setprop_u64(fdt_buf, chosen, "linux,initrd-start", RAMDISK_ENTRY);
	report("fdt_setprop_u64 linux,initrd-start", ret);
	ret = fdt_setprop_u64(fdt_buf, chosen, "linux,initrd-end", RAMDISK_ENTRY + RAMDISK_SIZE);
	report("fdt_setprop_u64 linux,initrd-end", ret);
	expect_prop("/chosen", "linux,initrd-start", &initrd_start, 8);
	expect_prop("/chosen", "linux,initrd-end", &initrd_end, 8);
	mism = compare_trees(blob_dtb, fdt_buf);
	check("tree matches blob + initrd props", mism == 0);
	out("  checksum after step 2 "); out_hex(fnv1a(fdt_buf, fdt_totalsize(fdt_buf))); out("\n");

	/* step 3: cmdline handler */
	out("step 3: cmdline handler\n");
	len = cmdline_size;
	if (len > (int)sizeof(str) - 1)
		len = sizeof(str) - 1;
#ifdef CMDLINE_COPY_OPTIMIZED
	out("  __optimized_memcpy(str, cmdline, ");
#else
	out("  memcpy(str, cmdline, ");
#endif
	out_dec(len); out(") from "); out_hex((unsigned long)blob_cmdline);
	out(" (src mod 16 = "); out_dec((unsigned long)blob_cmdline & 15);
	out(", dst mod 16 = "); out_dec((unsigned long)str & 15); out(")\n");
#ifdef CMDLINE_COPY_OPTIMIZED
	plat_mark_fault_site("__optimized_memcpy(str, cmdline, len) in cmdline_handler_patch_dtb");
	__optimized_memcpy(str, blob_cmdline, len);
#else
	plat_mark_fault_site("memcpy(str, cmdline, len) in cmdline_handler_patch_dtb");
	memcpy(str, blob_cmdline, len);
#endif
	plat_mark_fault_site(NULL);
	str[len] = '\0';
	check("memcpy result matches blob", memcmp(str, blob_cmdline, len) == 0);
	out("  strlen(str) "); out_dec(strlen(str)); out("\n");

	chosen = fdt_path_offset(fdt_buf, "/chosen");
	report("fdt_path_offset /chosen", chosen);
	old_bootargs = fdt_getprop(fdt_buf, chosen, "bootargs", &old_len);
	splice_bytes = fdt_off_dt_strings(fdt_buf) + fdt_size_dt_strings(fdt_buf)
		- ((const char *)old_bootargs + old_len - fdt_buf);
	out("  bootargs old len "); out_dec(old_len); out(" new len "); out_dec(strlen(str) + 1);
	out(", splice moves "); out_dec(splice_bytes); out(" bytes by ");
	out_dec((long)TAGALIGN(strlen(str) + 1) - (long)TAGALIGN(old_len)); out("\n");
	ret = fdt_setprop_string(fdt_buf, chosen, "bootargs", str);
	report("fdt_setprop_string bootargs", ret);
	expect_prop("/chosen", "bootargs", str, strlen(str) + 1);
	mism = compare_trees(blob_dtb, fdt_buf);
	check("tree matches blob + initrd props + bootargs", mism == 0);
	got = fdt_getprop(fdt_buf, chosen, "bootargs", &len);
	check("bootargs reads back", got && len == (int)strlen(str) + 1 && !memcmp(got, str, len));
	report("fdt_check_header", fdt_check_header(fdt_buf));
	out("  checksum after step 3 "); out_hex(fnv1a(fdt_buf, fdt_totalsize(fdt_buf))); out("\n");
	out("  totalsize "); out_dec(fdt_totalsize(fdt_buf));
	out(" struct "); out_dec(fdt_size_dt_struct(fdt_buf));
	out(" strings "); out_dec(fdt_size_dt_strings(fdt_buf)); out("\n");

	plat_dump(fdt_buf, fdt_totalsize(fdt_buf));

	/* step 4: overlap behaviour of the asm memmove; with the MMU off the
	 * unaligned cases also show whether memcpy.S tolerates Device memory */
	out("step 4: memmove overlap (asm memcpy.S alias)\n");
	check("forward +4, 3000 bytes", overlap_case(4, 3000, 64));
	check("forward +20, 3000 bytes", overlap_case(20, 3000, 64));
	check("forward +2, 3001 bytes", overlap_case(2, 3001, 64));
	check("backward -4, 3000 bytes", overlap_case(-4, 3000, 64));
	check("backward -20, 3000 bytes", overlap_case(-20, 3000, 64));
	check("forward +16, 8000 bytes", overlap_case(16, 8000, 64));
	check("forward +1, 100 bytes", overlap_case(1, 100, 64));
	check("forward +3, 20 bytes", overlap_case(3, 20, 64));
	/* all-aligned cases stay on the ldp/stp path */
	check("forward +8, 4096 bytes (aligned)", overlap_case(8, 4096, 64));
	check("backward -8, 4096 bytes (aligned)", overlap_case(-8, 4096, 64));
	check("forward +4096, 4000 bytes (aligned, no overlap)", overlap_case(4096, 4000, 64));
	check("forward +4096, 4001 bytes (odd count, no overlap)", overlap_case(4096, 4001, 64));
	check("forward +4097, 4000 bytes (odd dst, no overlap)", overlap_case(4097, 4000, 64));

done:
	out(failures ? "RESULT: FAIL (" : "RESULT: PASS (");
	out_dec(failures);
	out(" failures)\n");
	return failures ? 1 : 0;
}
