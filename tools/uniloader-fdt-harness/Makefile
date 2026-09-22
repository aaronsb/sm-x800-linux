# Host harness for uniLoader's DTB patching path. See README.md.
#
# Builds two aarch64 binaries from uniLoader's own sources with clang + lld:
#   harness-linux  static Linux user-mode ELF, run with qemu-aarch64
#   harness-virt   bare-metal ELF for qemu-system-aarch64 -M virt (MMU off)
#
# Knobs:
#   UL=              uniLoader tree (default ../../reference/uniLoader)
#   MEMCPY_S=        memcpy.S to link (default $(UL)/arch/aarch64/memcpy.S)
#   LIBFDT_MEMMOVE=  byteloop (default, what uniLoader does) | asm
#   CMDLINE_COPY=    memcpy (default: arch memcpy.S) | optimized (__optimized_memcpy)
#   O=               output directory (default build)

UL             ?= $(abspath ../../reference/uniLoader)
MEMCPY_S       ?= $(UL)/arch/aarch64/memcpy.S
LIBFDT_MEMMOVE ?= byteloop
CMDLINE_COPY   ?= memcpy
O              ?= build

BLOB_DTB       ?= $(UL)/blob/dtb
BLOB_CMDLINE   ?= $(UL)/blob/cmdline
BLOB_RAMDISK   ?= $(UL)/blob/ramdisk
RAMDISK_SIZE   := $(shell stat -c%s $(BLOB_RAMDISK))

CLANG   ?= clang
LLD     ?= ld.lld
TARGET  := --target=aarch64-linux-gnu
QEMU_USER ?= qemu-aarch64
QEMU_SYS  ?= qemu-system-aarch64

# Mirror uniLoader's KBUILD_CFLAGS: no -O flag (so -O0), its own headers only.
CFLAGS  := $(TARGET) -march=armv8-a -O0 -Wall -Wundef -Wno-trigraphs \
           -fno-strict-aliasing -fno-common -fno-stack-protector \
           -fno-builtin -ffreestanding -fno-pie -fno-PIC -nostdinc \
           -I$(UL)/lib/unic -I$(UL)/include -I$(UL)/include/lib/libfdt \
           -DHARNESS_VARIANT='"libfdt memmove: $(LIBFDT_MEMMOVE), cmdline copy: $(CMDLINE_COPY)"' \
           -DRAMDISK_SIZE=$(RAMDISK_SIZE)UL
AFLAGS  := $(TARGET) -march=armv8-a -D__ASSEMBLY__ -I$(UL)/arch/aarch64 \
           -DBLOB_DTB='"$(BLOB_DTB)"' -DBLOB_CMDLINE='"$(BLOB_CMDLINE)"'

ifeq ($(CMDLINE_COPY),optimized)
CFLAGS += -DCMDLINE_COPY_OPTIMIZED
endif

ifeq ($(LIBFDT_MEMMOVE),asm)
LIBFDT_CFLAGS := -include $(CURDIR)/shim-asm-memmove.h
endif

LIBFDT_SRCS := fdt.c fdt_ro.c fdt_rw.c fdt_wip.c fdt_sw.c fdt_strerror.c
LIBFDT_OBJS := $(patsubst %.c,$(O)/libfdt/%.o,$(LIBFDT_SRCS))
COMMON_OBJS := $(LIBFDT_OBJS) $(O)/string.o $(O)/memcpy.o $(O)/blobs.o $(O)/harness.o

all: $(O)/harness-linux $(O)/harness-virt

$(O)/libfdt/%.o: $(UL)/lib/libfdt/%.c | $(O)/libfdt
	$(CLANG) $(CFLAGS) $(LIBFDT_CFLAGS) -c -o $@ $<

$(O)/string.o: $(UL)/lib/unic/string.c | $(O)
	$(CLANG) $(CFLAGS) -c -o $@ $<

$(O)/memcpy.o: $(MEMCPY_S) | $(O)
	$(CLANG) $(AFLAGS) -c -o $@ $<

$(O)/blobs.o: blobs.S $(BLOB_DTB) $(BLOB_CMDLINE) | $(O)
	$(CLANG) $(AFLAGS) -c -o $@ $<

$(O)/harness.o: harness.c plat.h | $(O)
	$(CLANG) $(CFLAGS) -c -o $@ $<

$(O)/plat_linux.o: plat_linux.c plat.h | $(O)
	$(CLANG) $(CFLAGS) -c -o $@ $<

$(O)/plat_virt.o: plat_virt.c plat.h | $(O)
	$(CLANG) $(CFLAGS) -c -o $@ $<

$(O)/start_virt.o: start_virt.S | $(O)
	$(CLANG) $(AFLAGS) -c -o $@ $<

$(O)/harness-linux: $(COMMON_OBJS) $(O)/plat_linux.o
	$(LLD) -static -nostdlib -e _start -o $@ $^

$(O)/harness-virt: $(COMMON_OBJS) $(O)/plat_virt.o $(O)/start_virt.o virt.ld
	$(LLD) -static -nostdlib -T virt.ld -o $@ $(filter %.o,$^)

$(O) $(O)/libfdt:
	mkdir -p $@

# Run: user mode (no alignment checking: Linux user space allows unaligned access)
run-linux: $(O)/harness-linux
	$(QEMU_USER) $< > $(O)/patched.dtb

# Run: bare metal with the MMU off, as ABL hands the CPU to uniLoader
run-virt: $(O)/harness-virt
	$(QEMU_SYS) -M virt -cpu cortex-a53 -m 256 -nographic -no-reboot \
	    -semihosting-config enable=on,target=native -kernel $<

run: run-linux run-virt

clean:
	rm -rf $(O)

.PHONY: all run run-linux run-virt clean
