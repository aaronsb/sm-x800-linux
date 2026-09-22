// SPDX-License-Identifier: GPL-2.0-only
#ifndef PLAT_H_
#define PLAT_H_

void plat_puts(const char *s);
void plat_banner(void);
void plat_dump(const void *buf, unsigned long len);
void plat_mark_fault_site(const char *what);
void plat_exit(int code) __attribute__((noreturn));

#endif
