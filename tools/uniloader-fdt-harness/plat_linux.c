// SPDX-License-Identifier: GPL-2.0-only
/*
 * Linux user-mode platform layer: raw syscalls, no libc. Text goes to
 * stderr, the patched DTB to stdout (redirect it to a file).
 */
#include <string.h>
#include "plat.h"

static long sys3(long nr, long a, long b, long c)
{
	register long x8 __asm__("x8") = nr;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
	return x0;
}

static void write_all(int fd, const void *buf, unsigned long len)
{
	const char *p = buf;

	while (len) {
		long n = sys3(64, fd, (long)p, len);
		if (n <= 0)
			return;
		p += n;
		len -= n;
	}
}

void plat_puts(const char *s) { write_all(2, s, strlen(s)); }

void plat_banner(void) { plat_puts("platform: linux user mode (qemu-aarch64 or native)\n"); }

void plat_dump(const void *buf, unsigned long len)
{
	plat_puts("  writing patched blob to stdout\n");
	write_all(1, buf, len);
}

void plat_mark_fault_site(const char *what) { (void)what; }

void plat_exit(int code)
{
	for (;;)
		sys3(94, code, 0, 0);
}

int main(void);

__attribute__((naked, section(".text.start"))) void _start(void)
{
	__asm__ volatile(
		"bl main\n"
		"bl plat_exit\n");
}
