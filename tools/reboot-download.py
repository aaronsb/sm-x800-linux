#!/usr/bin/env python3
"""Reboot the device straight into Samsung download mode. Run as root ON DEVICE.

Every flash cycle otherwise needs the physical dance: hold Power+VolDown to kill
it, then plug the cable while holding both volume keys. This asks the kernel to
hand the bootloader a reboot reason instead.

MECHANISM: reboot(2) with LINUX_REBOOT_CMD_RESTART2 takes an arbitrary string
that the platform's restart handler passes to firmware. On Qualcomm the
reboot-mode driver writes it to a PON/IMEM register that the bootloader reads on
the next boot. "download" is Samsung's mode for the Odin/LOKE downloader.

THIS MAY SIMPLY NOT WORK, and that is a legitimate outcome worth recording:
mainline needs the reboot-mode plumbing described in DT (a `reboot-mode` node
with `mode-download = <...>` under the PON block, or qcom,pmk8350-pon support
for it). If the string is unrecognised the kernel falls back to a NORMAL reboot,
so the failure mode is benign -- you get a regular boot, not a brick.

Tries several spellings other Samsung/Qualcomm devices use before giving up.

Usage:  reboot-download.py [--dry-run] [mode]
"""

import ctypes
import os
import sys

# aarch64 syscall number for reboot(2)
SYS_REBOOT = 142

LINUX_REBOOT_MAGIC1 = 0xFEE1DEAD
LINUX_REBOOT_MAGIC2 = 672274793          # 0x28121969
LINUX_REBOOT_CMD_RESTART2 = 0xA1B2C3D4

# Spellings seen across Samsung / Qualcomm downstream trees.
CANDIDATES = ["download", "bootloader", "sec_debug_hw_reset", "odin", "dload"]


def reboot_with(mode: str) -> int:
    libc = ctypes.CDLL(None, use_errno=True)
    buf = ctypes.create_string_buffer(mode.encode() + b"\0")
    ctypes.set_errno(0)
    rc = libc.syscall(
        ctypes.c_long(SYS_REBOOT),
        ctypes.c_ulong(LINUX_REBOOT_MAGIC1),
        ctypes.c_ulong(LINUX_REBOOT_MAGIC2),
        ctypes.c_ulong(LINUX_REBOOT_CMD_RESTART2),
        buf,
    )
    return rc if rc == 0 else -ctypes.get_errno()


def report_support():
    """Show whether anything in this kernel claims to handle reboot modes."""
    print("=== reboot-mode support evidence ===")
    for p in ("/sys/kernel/reboot/mode", "/sys/module/qcom_pon", "/sys/module/reboot_mode"):
        print(f"  {p}: {'present' if os.path.exists(p) else 'absent'}")
    hits = []
    try:
        with open("/sys/firmware/devicetree/base/__symbols__/pon", "rb") as f:
            hits.append("DT has a pon symbol")
    except OSError:
        pass
    for root, dirs, files in os.walk("/sys/firmware/devicetree/base"):
        if "reboot-mode" in os.path.basename(root) or "mode-download" in files:
            hits.append(root)
            if len(hits) > 4:
                break
    print("  DT reboot-mode nodes:", hits if hits else "none found")
    print("  (no DT reboot-mode node => the string is ignored and you get a")
    print("   normal reboot; that is the expected benign failure)")


def main():
    args = [a for a in sys.argv[1:]]
    dry = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    modes = args if args else CANDIDATES

    if os.geteuid() != 0:
        print("must run as root", file=sys.stderr)
        return 1

    report_support()
    print()
    if dry:
        print("dry run; would try:", ", ".join(modes))
        return 0

    os.system("sync")
    for mode in modes:
        print(f"=== trying reboot mode {mode!r} ===")
        rc = reboot_with(mode)
        # If we are still alive, the call returned instead of rebooting.
        print(f"  returned {rc} (errno {-rc if rc < 0 else 0}) -- still running, trying next")
    print()
    print("No mode caused a reboot. This kernel does not implement RESTART2 for")
    print("this platform; download mode has to be entered by hand.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
