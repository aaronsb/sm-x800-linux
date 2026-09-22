/*
 * Force-included when LIBFDT_MEMMOVE=asm: makes uniLoader's libfdt call the
 * assembly memmove/memcpy from arch/aarch64/memcpy.S instead of the byte
 * loop __optimized_memmove it uses in the real build.
 */
#include <string.h>
#define __optimized_memmove memmove
#define __optimized_memcpy memcpy
