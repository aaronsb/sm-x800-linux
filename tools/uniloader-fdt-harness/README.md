# uniLoader DTB patch harness

Runs the DTB patching that uniLoader does on the tablet, on the host, against
uniLoader's own sources: `lib/libfdt/*.c`, `lib/unic/string.c` and
`arch/aarch64/memcpy.S` from `reference/uniLoader`, with `blob/dtb` and
`blob/cmdline` embedded. The sequence is the one in `main/boot-fdt.c`:

1. `fdt_open_into(blob/dtb, fdt_buf, CONFIG_FDT_BUF_SIZE)`
2. `fdt_setprop_u64` for `linux,initrd-start` and `linux,initrd-end`
3. `memcpy(str, cmdline, cmdline_size)`, then `fdt_setprop_string` bootargs
4. overlap cases against the asm `memmove`

After each step the buffer is compared with the original blob node by node
and property by property; only the initrd properties and bootargs may
differ. Return codes, splice sizes and an FNV-1a checksum are printed. In
user mode the patched blob is written to stdout for `dtc`.

Two binaries are built from the same objects:

| binary          | runs under                          | what it shows                                    |
|-----------------|-------------------------------------|--------------------------------------------------|
| `harness-linux` | `qemu-aarch64` (Linux user mode)    | libfdt logic and memmove overlap correctness      |
| `harness-virt`  | `qemu-system-aarch64 -M virt`, EL1, MMU off | the tablet's memory model: Device-nGnRnE, alignment faults |

The bare-metal run installs exception vectors that print ESR, ELR and FAR
and exit, so an alignment fault is reported instead of a hang.

## Prerequisites

`clang`, `ld.lld`, `llvm-objdump` (any recent LLVM), `qemu-aarch64`,
`qemu-system-aarch64` (8.2 or newer: alignment checking on Device memory),
`dtc`. No aarch64 sysroot is needed; the harness is freestanding.

## Run

```sh
cd tools/uniloader-fdt-harness
make                # builds build/harness-linux and build/harness-virt
make run-linux      # user mode; writes build/patched.dtb
make run-virt       # bare metal, MMU off
```

Knobs (make variables):

| variable          | default                          | purpose                                              |
|-------------------|----------------------------------|------------------------------------------------------|
| `UL`              | `../../reference/uniLoader`      | uniLoader tree                                       |
| `MEMCPY_S`        | `$(UL)/arch/aarch64/memcpy.S`    | memcpy.S to link, e.g. the unpatched upstream file   |
| `LIBFDT_MEMMOVE`  | `byteloop`                       | `asm` makes libfdt call the asm memmove/memcpy       |
| `CMDLINE_COPY`    | `memcpy`                         | `optimized` copies the blob with `__optimized_memcpy` instead of memcpy.S |
| `O`               | `build`                          | output directory; use one per variant                |

Check the user-mode result with dtc:

```sh
dtc -q -I dtb -O dts -o build/patched.dts build/patched.dtb
dtc -q -I dtb -O dts -o build/orig.dts ../../reference/uniLoader/blob/dtb
diff build/orig.dts build/patched.dts
```

To run the unpatched upstream memcpy.S:

```sh
git -C ../../reference/uniLoader show 43770a0:arch/aarch64/memcpy.S > /tmp/ul-memcpy-43770a0.S
make O=build-orig MEMCPY_S=/tmp/ul-memcpy-43770a0.S run-virt
```

`MEMCPY_S` is read at build time only; check `llvm-objdump -d build-orig/memcpy.o`
when in doubt about which file was linked.

## Results, 2026-09-21

uniLoader's libfdt does not use the asm memmove. `fdt_rw.c` calls
`__optimized_memmove`, a byte loop from `lib/unic/string.h`, which is
overlap-safe. The asm memcpy.S (Arm optimized-routines) is overlap-safe
too: every case in step 4 passes in user mode.

| run                                             | result                                                        |
|-------------------------------------------------|---------------------------------------------------------------|
| linux, upstream memcpy.S, 253-byte blob         | PASS, all steps                                               |
| linux, upstream memcpy.S, `LIBFDT_MEMMOVE=asm`  | PASS, same checksums                                          |
| virt (MMU off), upstream memcpy.S, 253-byte blob | steps 1 and 2 PASS; step 3 Alignment fault in `memcpy(str, cmdline, 253)`: ESR_EL1 0x96000021, FAR = cmdline + 189 (mod 8 = 5), at `ldp E_l, E_h, [srcend, -64]` |
| virt (MMU off), upstream memcpy.S, 274-byte blob | same fault, FAR = cmdline + 210                              |
| virt (MMU off), upstream memcpy.S, `CMDLINE_COPY=optimized` | steps 1 to 3 PASS; step 4 Alignment fault in the first unaligned memmove case |
| virt (MMU off), patched memcpy.S, 274-byte blob  | PASS, all steps, bootargs grows 253 to 274 bytes and the splice moves 119904 bytes by 20 |
| linux, patched memcpy.S, 274-byte blob          | PASS; dtc shows only the initrd properties and bootargs changed |

With the MMU off every data access is to Device-nGnRnE memory, where an
unaligned access is an Alignment fault. The upstream memcpy.S loads and
stores the last 64 bytes of any region over 128 bytes relative to its end,
so an odd count faults. The kernel and DTB copies have page-aligned bases
and counts that are multiples of 16 and never reach that case. The fix is
`pmaports-overlay/uniloader-port/patches/0004-memcpy-strict-align.patch`:
memcpy/memmove take a byte loop unless src, dst and count are all multiples
of 8, and C code is built with `-mstrict-align`.
