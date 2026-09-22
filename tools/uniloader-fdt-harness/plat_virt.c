// SPDX-License-Identifier: GPL-2.0-only
/*
 * Bare-metal platform layer for qemu-system-aarch64 -M virt: PL011 UART,
 * exception vectors that report ESR/ELR/FAR, exit through semihosting.
 * The CPU runs exactly as ABL hands it to uniLoader: MMU off, so every
 * data access is Device-nGnRnE and an unaligned one is an Alignment fault.
 */
#include <string.h>
#include "plat.h"

#define UART_DR ((volatile unsigned int *)0x09000000UL)
#define UART_FR ((volatile unsigned int *)0x09000018UL)

static const char *fault_site;

static void putc_(char c)
{
	while (*UART_FR & (1 << 5))
		;
	*UART_DR = c;
}

void plat_puts(const char *s)
{
	while (*s)
		putc_(*s++);
}

static void put_hex(unsigned long v)
{
	int i;

	plat_puts("0x");
	for (i = 0; i < 16; i++)
		putc_("0123456789abcdef"[(v >> (60 - 4 * i)) & 0xf]);
}

static unsigned long rd_currentel(void) { unsigned long v; __asm__("mrs %0, currentel" : "=r"(v)); return v; }
static unsigned long rd_sctlr(void) { unsigned long v; __asm__("mrs %0, sctlr_el1" : "=r"(v)); return v; }

void plat_banner(void)
{
	unsigned long sctlr = rd_sctlr();

	plat_puts("platform: qemu -M virt bare metal, EL");
	putc_('0' + (rd_currentel() >> 2));
	plat_puts(", SCTLR_EL1 ");
	put_hex(sctlr);
	plat_puts(sctlr & 1 ? " (MMU on)" : " (MMU off: data accesses are Device-nGnRnE)");
	plat_puts(sctlr & 2 ? ", A=1" : ", A=0");
	plat_puts("\n");
}

void plat_dump(const void *buf, unsigned long len) { (void)buf; (void)len; }

void plat_mark_fault_site(const char *what) { fault_site = what; }

extern const unsigned char blob_cmdline[];

static const char *dfsc_name(unsigned long dfsc)
{
	switch (dfsc) {
	case 0x21: return "Alignment fault";
	case 0x04: case 0x05: case 0x06: case 0x07: return "Translation fault";
	case 0x0d: case 0x0e: case 0x0f: return "Permission fault";
	case 0x10: return "Synchronous external abort";
	default: return "other";
	}
}

void plat_exception(unsigned long esr, unsigned long elr, unsigned long far, unsigned long vec)
{
	unsigned long ec = (esr >> 26) & 0x3f;

	plat_puts("\nEXCEPTION vector ");
	putc_('0' + vec);
	plat_puts(" ESR_EL1 "); put_hex(esr);
	plat_puts(" EC "); put_hex(ec);
	if (ec == 0x25 || ec == 0x24) {
		plat_puts(" data abort, DFSC "); put_hex(esr & 0x3f);
		plat_puts(" "); plat_puts(dfsc_name(esr & 0x3f));
		plat_puts(esr & (1 << 6) ? ", write" : ", read");
	}
	plat_puts("\n  ELR_EL1 "); put_hex(elr);
	plat_puts("\n  FAR_EL1 "); put_hex(far);
	plat_puts(" (cmdline + "); 
	{
		long d = (long)far - (long)blob_cmdline;
		char b[24]; int i = 23; unsigned long u = d < 0 ? -d : d;
		b[i] = 0; do { b[--i] = '0' + u % 10; u /= 10; } while (u);
		if (d < 0) b[--i] = '-';
		plat_puts(b + i);
	}
	plat_puts(", mod 8 = "); putc_('0' + (far & 7)); plat_puts(")\n");
	if (fault_site) {
		plat_puts("  while executing: ");
		plat_puts(fault_site);
		plat_puts("\n");
	}
	plat_puts("RESULT: FAULT\n");
	plat_exit(2);
}

void plat_exit(int code)
{
	/* semihosting SYS_EXIT_EXTENDED: {ADP_Stopped_ApplicationExit, code} */
	static unsigned long block[2];
	register unsigned long x0 __asm__("x0") = 0x20;
	register unsigned long x1 __asm__("x1");

	block[0] = 0x20026;
	block[1] = code;
	x1 = (unsigned long)block;
	__asm__ volatile("hlt #0xf000" : : "r"(x0), "r"(x1) : "memory");
	/* fallback: PSCI SYSTEM_OFF */
	for (;;)
		__asm__ volatile("mov x0, #0x84000000\n"
				 "add x0, x0, #8\n"
				 "hvc #0" : : : "x0", "memory");
}
