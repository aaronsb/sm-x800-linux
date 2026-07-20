#!/usr/bin/env python3
"""Minimal STM32 I2C ROM-bootloader client for the pogo Book Cover Keyboard MCU.

Runs ON THE DEVICE. Executes exactly ONE command per invocation, because the
bootloader must be freshly pulsed for each one (see below). The caller
(pogo-stm32-info.sh) drives BOOT0/nRST and re-pulses between invocations.

    stm32boot.py <bus> {getid|get|getver|read [addr] [len]|go [addr]}

Protocol (ST AN4221, I2C bootloader), address 0x51:
    command frame = 2 bytes: [cmd, cmd ^ 0xFF]
    status byte:  ACK = 0x79, NACK = 0x1F

*** BOOTLOADER STATE HYGIENE -- this cost us a debugging round. ***
The bootloader wedges after ANY stray or malformed traffic and then times out
on everything until the next nRST/BOOT0 pulse. Observed directly:
  - a bare 1-byte read (no command pending) returns 0x1F and POISONS the state;
    every subsequent command frame returns ETIMEDOUT
  - an incomplete frame (writing cmd without its complement, as two separate
    1-byte transactions) wedges it the same way
  - a multi-byte read with no command pending wedges it
  - immediately after a fresh pulse, `w2 0x02 0xfd` then `r1` cleanly returns
    0x79
So: NEVER probe "is it there?" before issuing a command. The probe is what
breaks it. Issue the real command frame first and let its ACK be the proof.

READ ONLY. No erase, no write is implemented here, deliberately.
"""

import fcntl
import os
import sys
import time

I2C_SLAVE = 0x0703
ADDR = 0x51
ACK = 0x79
NACK = 0x1F

CMD_GET = 0x00
CMD_GET_VERSION = 0x01
CMD_GET_ID = 0x02
CMD_READ_MEMORY = 0x11
CMD_GO = 0x21

APP_FLASH_BASE = 0x08000000

CMD_NAMES = {
    0x00: "Get", 0x01: "Get Version", 0x02: "Get ID",
    0x11: "Read Memory", 0x21: "Go", 0x31: "Write Memory",
    0x43: "Erase", 0x44: "Extended Erase", 0x63: "Write Protect",
    0x64: "Write Unprotect", 0x73: "Readout Protect",
    0x82: "Readout Unprotect", 0x92: "Get Checksum",
}

# Known STM32 product IDs (bootloader GET-ID values).
PIDS = {
    0x412: "STM32F10x Low-density", 0x410: "STM32F10x Medium-density",
    0x414: "STM32F10x High-density", 0x420: "STM32F10x Medium-density VL",
    0x411: "STM32F2xx", 0x413: "STM32F40x/41x", 0x419: "STM32F42x/43x",
    0x431: "STM32F411", 0x441: "STM32F412", 0x421: "STM32F446",
    0x434: "STM32F469/479", 0x449: "STM32F74x/75x", 0x451: "STM32F76x/77x",
    0x440: "STM32F03x/05x", 0x442: "STM32F09x", 0x444: "STM32F03x",
    0x445: "STM32F04x", 0x448: "STM32F07x",
    0x457: "STM32L01x/02x", 0x425: "STM32L03x/04x", 0x417: "STM32L05x/06x",
    0x416: "STM32L1xx Medium-density", 0x429: "STM32L1xx MD+",
    0x427: "STM32L1xx High-density", 0x436: "STM32L1xx HD+", 0x437: "STM32L1xx XL",
    0x435: "STM32L43x/44x", 0x462: "STM32L45x/46x", 0x415: "STM32L47x/48x",
    0x461: "STM32L496/4A6", 0x470: "STM32L4Rx/4Sx",
    0x468: "STM32G43x/44x", 0x469: "STM32G47x/48x", 0x479: "STM32G49x/4Ax",
    0x466: "STM32G03x/04x", 0x456: "STM32G05x/06x", 0x453: "STM32G07x/08x",
    0x452: "STM32F72x/73x",
    0x450: "STM32H74x/75x", 0x480: "STM32H7Ax/7Bx",
    0x482: "STM32U57x/58x", 0x455: "STM32WBxx", 0x497: "STM32WLEx",
}


class Bootloader:
    def __init__(self, bus=0, addr=ADDR, settle=0.01):
        self.fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)
        fcntl.ioctl(self.fd, I2C_SLAVE, addr)
        self.settle = settle

    def close(self):
        os.close(self.fd)

    def _w(self, data):
        os.write(self.fd, bytes(data))
        time.sleep(self.settle)

    def _r(self, n):
        time.sleep(self.settle)
        return os.read(self.fd, n)

    def _status(self, what):
        b = self._r(1)
        if not b:
            raise IOError(f"{what}: no status byte")
        if b[0] == ACK:
            return True
        if b[0] == NACK:
            raise IOError(f"{what}: NACK (0x1f)")
        raise IOError(f"{what}: unexpected status 0x{b[0]:02x}")

    def cmd(self, c, name):
        self._w([c, c ^ 0xFF])
        self._status(name)

    def get(self):
        self.cmd(CMD_GET, "GET")
        n = self._r(1)[0]
        payload = self._r(n + 1)
        self._status("GET trailer")
        return payload[0], list(payload[1:])

    def get_version(self):
        self.cmd(CMD_GET_VERSION, "GET-VERSION")
        v = self._r(3)
        self._status("GET-VERSION trailer")
        return v

    def get_id(self):
        self.cmd(CMD_GET_ID, "GET-ID")
        n = self._r(1)[0]
        pid = self._r(n + 1)
        self._status("GET-ID trailer")
        return int.from_bytes(pid, "big")

    def go(self, addr):
        """Jump to application code. Non-destructive: nothing is written.

        If the app comes alive after this but not after a normal reset, the
        firmware is fine and the fault is in how the MCU enters the app.
        """
        self.cmd(CMD_GO, "GO")
        a = list(addr.to_bytes(4, "big"))
        chk = 0
        for b in a:
            chk ^= b
        self._w(a + [chk])
        self._status("GO address")
        return True

    def read_memory(self, addr, length):
        if not (1 <= length <= 256):
            raise ValueError("length must be 1..256")
        self.cmd(CMD_READ_MEMORY, "READ-MEMORY")
        a = list(addr.to_bytes(4, "big"))
        chk = 0
        for b in a:
            chk ^= b
        self._w(a + [chk])
        self._status("READ-MEMORY address")
        n = length - 1
        self._w([n, n ^ 0xFF])
        self._status("READ-MEMORY count")
        return self._r(length)


def verdict(data, base):
    for off in range(0, min(len(data), 64), 16):
        row = data[off:off + 16]
        print(f"  {base + off:08x}  " + " ".join(f"{b:02x}" for b in row))
    if len(data) > 64:
        print("  ...")
    print()
    if all(b == 0xFF for b in data):
        print("  VERDICT: flash is BLANK (all 0xFF) -- NO application firmware.")
        print("           Fully explains the crash loop. Needs reflashing.")
        return
    if all(b == 0x00 for b in data):
        print("  VERDICT: all zeros -- erased-to-zero or unreadable.")
        return
    sp = int.from_bytes(data[0:4], "little")
    pc = int.from_bytes(data[4:8], "little")
    print(f"  initial SP : 0x{sp:08x}")
    print(f"  reset PC   : 0x{pc:08x}")
    sp_ok = 0x20000000 <= sp <= 0x20050000
    pc_ok = 0x08000000 <= pc <= 0x08100000 and bool(pc & 1)
    if sp_ok and pc_ok:
        print("  VERDICT: PLAUSIBLE Cortex-M vector table present.")
        print("           Firmware exists but does not run -- suspect corruption")
        print("           further in, or a runtime fault.")
    else:
        print(f"  VERDICT: vector table INVALID (SP {'ok' if sp_ok else 'BAD'}, "
              f"PC {'ok' if pc_ok else 'BAD'}).")
        print("           MCU would fault immediately on reset -- matches the")
        print("           observed ~95ms crash loop.")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    bus = int(sys.argv[1])
    what = sys.argv[2]
    bl = Bootloader(bus=bus)
    try:
        if what == "getid":
            pid = bl.get_id()
            name = PIDS.get(pid, "unknown part")
            print(f"  product ID: 0x{pid:03x}  ({name})")
        elif what == "getver":
            v = bl.get_version()
            print(f"  version 0x{v[0]:02x} = {v[0] >> 4}.{v[0] & 0xF}, "
                  f"option bytes {v[1]:02x} {v[2]:02x}")
        elif what == "get":
            ver, cmds = bl.get()
            print(f"  bootloader version : {ver >> 4}.{ver & 0xF} (raw 0x{ver:02x})")
            print("  supported commands :")
            for c in cmds:
                print(f"    0x{c:02x}  {CMD_NAMES.get(c, '?')}")
            if CMD_READ_MEMORY not in cmds:
                print("  !! READ MEMORY not offered -- flash is readout-protected")
        elif what == "go":
            addr = int(sys.argv[3], 0) if len(sys.argv) > 3 else APP_FLASH_BASE
            bl.go(addr)
            print(f"  GO 0x{addr:08x} ACKed -- MCU jumped to application")
        elif what == "read":
            addr = int(sys.argv[3], 0) if len(sys.argv) > 3 else APP_FLASH_BASE
            ln = int(sys.argv[4], 0) if len(sys.argv) > 4 else 256
            data = bl.read_memory(addr, ln)
            verdict(data, addr)
        else:
            print(f"  unknown command: {what}")
            return 2
    except Exception as e:
        print(f"  FAILED: {e}")
        return 1
    finally:
        bl.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
