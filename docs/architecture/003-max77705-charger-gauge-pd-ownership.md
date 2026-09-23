---
status: Accepted
date: 2026-09-23
deciders:
  - aaronsb
  - claude
related:
  - https://github.com/aaronsb/sm-x800-linux/issues/9
  - https://github.com/aaronsb/sm-x800-linux/issues/49
  - https://github.com/aaronsb/sm-x800-linux/issues/53
  - https://github.com/aaronsb/sm-x800-linux/pull/54
---

# ADR-003: MAX77705 ownership on mainline: upstream MFD, charger and gauge, and a new CCIC/PD Type-C driver, in stages

## Context

The MAX77705 is the tablet's power companion. One package on i2c5
(mainline bus 4) answers at four addresses:

| address | function | reads on mainline, 2026-09-23 |
|---|---|---|
| 0x66 | top: interrupts, revision | ID 0x15, `PMICREV` 0x02 (PASS2) |
| 0x69 | charger, OTG boost | `CHG_CNFG_00` 0x05 (buck + charge) |
| 0x36 | fuel gauge, MAX17047 class | stock model intact, `Status` POR clear |
| 0x25 | CCIC: Type-C, BC1.2, USB PD | firmware 5F.00, product 9, masks all 0xFF |

What mainline describes today: an OTG-boost-only shim at 0x69
(`max77705-otg.c`), switched from userspace through `vbus-otg`, and since
kernel r31 the fuel gauge at 0x36 as a plain I2C client (PR #54). The top
and the CCIC are not described. dwc3 is fixed in host mode.

What that gives, measured on 2026-09-23:

- **Charging works with no driver.** The chip charges on its power-on
  defaults: 4.35 V float (`CNFG_04` 0x13), 2.1 A fast charge (`CNFG_02`),
  1.8 A input limit (`CNFG_09` 0x47). A USB-C charger and a PC port both
  gave about +0.9 to +1.0 A net into the battery at 5 V; the PC port
  engaged AICL. Stock's float voltage is 4.38 V.
- **5 V only.** The CCIC holds its default PDO until the host selects one
  (mailbox opcode 0x32), and nothing on mainline does. A PD-passthrough
  dongle with a charger on its input showed no attach at all
  (`CC_STATUS0` CCStat 0) and did not pass power to the tablet.
- **Host mode works; roles do not.** An RTL8153 dongle enumerated at high
  speed on the OTG boost (#9). The CCIC meanwhile reported itself a Sink
  seeing VBUS: it detects our own boost as input. Gadget mode cannot work,
  since dwc3 needs VBUS detection and a role switch. Turning VBUS on is a
  manual step, and its only guard is the shim refusing to start while
  `CHG_INT_OK` shows charger input.
- **Battery visibility** (r31): `max170xx_battery` reports capacity,
  voltage, current, temperature, cycles and time to empty. There is no
  charger `power_supply`, so `STATUS` stays Unknown.

Mainline 7.2 has upstream drivers for most of the chip: `mfd/max77705.c`
(top, one regmap-irq domain: CHG 0, TOP 1, FG 2, USBC 3),
`power/supply/max77705_charger.c`, the gauge through `max17042_battery.c`,
LEDs and haptic. Two gaps:

1. **The MFD rejects this chip.** It requires `PMICREV & 7 == PASS3`;
   ours reads 2. Stock maps ID 0x15 revision 2 to "MD15 PASS2", logical
   PASS5 (`kernel-src/drivers/mfd/maxim/max77705.c:92-96`).
2. **There is no Type-C/PD driver.** The upstream MAX77705 series
   covered charger, gauge, haptic and LED and left Type-C out. No
   max77705 typec driver has been posted.

The upstream charger driver also has no OTG regulator and cannot share
0x69 with our shim. At probe it enables charging, sets the float voltage
from the `monitored-battery` node (4.2 V without one), the input and
system thresholds, and the OTG current limit, and turns the watchdog off.
It does not set the fast-charge current.

The CCIC runs PD from its own flash. The firmware image stock would flash
is in the Samsung tree (`BOOT_FLASH_FW_PASS2`,
`include/linux/mfd/firmware/max77705C_pass2_specific.h`, header version
5F.00 product 9), and stock reflashes only when the chip reports an older
version. The chip already runs 5F.00, so mainline needs no image. The
host's job is a mailbox at 0x25: write `[opcode, data]` at 0x21, wait for
the APCmdRes interrupt, read the response at 0x51. The opcodes and
registers are mapped in the stock driver
(`drivers/usb/typec/maxim/max77705_{usbc,pd,cc}.c`,
`include/linux/usb/typec/maxim/max77705.h`); the ones this ADR relies on
are listed under Decision.

## Decision

Take the chip over in three stages. Each stage lands on its own and
leaves the tablet no worse off than the one before.

### Stage 1: visibility (done, r31)

The fuel gauge as a plain I2C client, read-only, with the
`max17042_id[]` patch. The charger runs on chip defaults; the OTG shim
keeps 0x69.

### Stage 2: upstream MFD and charger, OTG as a charger regulator

- **MFD revision patch.** Accept PASS2 in `mfd/max77705.c` for ID 0x15,
  with the stock mapping as the justification. Describe the top at 0x66
  with its interrupt, `pm8350c_gpios 5`, active low, as stock
  (`max77705,irq-gpio`).
- **Charger.** Replace the shim with the upstream `max77705-charger` as
  an MFD child, and a `simple-battery` node:
  `constant-charge-voltage-max-microvolt = <4380000>`,
  `charge-full-design-microamp-hours` from the gauge's DesignCap (8800
  mAh; stock's `battery_full_capacity` reads 9800),
  `voltage-min-design-microvolt` from stock's empty voltage. The
  charger's float voltage comes from this node and nowhere else.
- **OTG regulator in the upstream charger.** A patch that adds a
  `usb-otg-vbus` regulator to `max77705_charger.c`, with the shim's
  semantics: boost bits are ORed onto the current mode nibble
  (0x4 → 0xE, 0x5 → 0xF), never mode 0xA, which drops the system buck;
  refuse with -EBUSY while `CHG_INT_OK` shows charger input. Upstreamable
  on its own. The shim is deleted in the same change.
- **Gauge as MFD child.** The gauge moves under the top with interrupt
  FG (2) and `power-supplies` pointing at the charger. The r31 I2C-ID
  patch stays useful upstream but this board stops needing it.

### Stage 3: a new `max77705-usbc` Type-C driver

A driver in `drivers/usb/typec/`, bound as an MFD child on the USBC
interrupt (3), modelled on `rt1719.c` (firmware-PD sink with a typec
port, role switch and PDO selection).

- **Type-C port**, DRP and DRD. Attach from `CC_STATUS0` CCStat,
  orientation from CCPinStat, data role from `PD_STATUS1` bit 7. Reports
  to the typec class and drives `usb_role_switch` on dwc3: `&usb_1` goes
  back to `dr_mode = "otg"` with `usb-role-switch`. Gadget mode comes
  with it.
- **VBUS by attach.** `cc_SOURCE` (a sink partner) turns on the charger's
  OTG regulator; detach turns it off. The `vbus-otg` userspace switch is
  retired. Firmware auto-VBUS stays off, as stock sets it at init
  (opcode 0x54).
- **Sink PD, fixed PDOs only.** On PSRDY, read the source caps (opcode
  0x30). Pick the highest fixed PDO within stock's policy: at most 9 V,
  3 A and 15 W (`battery,max_input_voltage`, `max_input_current`,
  `pd_charging_charge_power`). Lower the charger input limit to
  min(old, new) **before** requesting (opcode 0x32); raise it after the
  next PSRDY confirms the contract. Program sink caps at init (opcode
  0x2E) from stock's `snkcap_data` minus the PPS entry. Set AUTOIBUS
  (opcode 0x57) to 1 as stock does, so firmware and host do not both
  write the input limit.
- **Mailbox discipline.** One command outstanding, a timeout, and on
  SYSMSG reporting a CCIC reset or watchdog, re-run the init opcodes
  (stock `usbc.c:2870-2925`).

### Invariants, all stages

- Never enter the CCIC firmware-update path: no write of 0xD0 to 0x25
  register 0x21, no opcode 0xD1, no `BOOT_FLASH` streaming, no
  `fw_update` attribute. The CCIC reset (0x25 register 0x80 = 0x0F) is
  recovery only.
- Never request an APDO/PPS contract. On stock PPS feeds the separate
  sm5440 direct charger (i2c 59-0063), which mainline does not drive.
- Fixed PDOs at or below 9 V only. A source-cap list with none acceptable
  stays at 5 V.
- The float voltage is set explicitly from the battery node; never the
  driver's 4.2 V fallback, never above 4.38 V.
- OTG boost and charger input are never on together.

## Consequences

### Positive

- Charging state becomes visible (`STATUS`, charger online, input
  limit), and suspend drain can be measured per hour (#49).
- On a PD charger, input power rises from about 9 W (5 V, 1.8 A) to
  stock's 15 W cap at 9 V.
- VBUS follows attach, so a sink device just works and a charger can
  never meet an active boost.
- Gadget mode (USB ethernet to a PC, the debug shell's ACM console)
  becomes possible through the role switch.
- Stages 2 and 3 are upstreamable pieces: the MFD revision, the charger
  OTG regulator, the typec driver.

### Negative

- Stage 3 is roughly 900 to 1200 lines of new driver against a protocol
  known only from vendor source, plus a DT binding. The riskiest parts
  are mailbox serialization and recovery, hard reset with charger input
  live, the PSRDY/PDMsg race stock works around (`pd.c:1492-1550`), and
  the dwc3 role-switch rewiring, which #53 shows is already fragile
  across suspend.
- Stage 2 hands charge control to a driver that rewrites charger
  settings at probe. A wrong battery node over-charges or under-charges
  a 9 Ah cell; the node needs review against stock before it ships.
- The MFD revision patch asserts that PASS2 behaves like PASS3 for what
  upstream touches (active discharge, interrupts). That is inferred from
  stock working on this revision, not shown.

### Neutral

- Stage 1 stays valid through the later stages; only the gauge's parent
  changes.
- DisplayPort alternate mode, the PS5169 SuperSpeed redriver, water
  detection and Samsung AFC stay out of scope.

## Alternatives Considered

- **Keep the shim and add a userspace PD daemon over i2c-dev.** No
  interrupt, a race with any kernel user of the same registers, and the
  safety invariants enforced by a process that can die. Rejected.
- **Port the Samsung stack** (`max77705_usbc/pd/cc/alternate`, MUIC,
  `sec_battery`). About 22,000 lines for the MAX77705 drivers and
  31,000 for the `sec_battery` framework and notifier chains they are
  tied to, and it carries the firmware-update path. Mined for the
  protocol; not ported.
- **TCPM with a TCPCI driver.** The MAX77705 CCIC is not a TCPCI port
  controller; it runs the PD policy in firmware and exposes a mailbox.
  The MAX77759 TCPCI series is a different architecture.
- **Stay at stage 1.** Safe, and 5 V charging works. It leaves VBUS as a
  manual switch with a weak guard, no gadget mode, and no charging state.
  Acceptable as a resting point, not as the end state.
- **Our own charger driver instead of upstream's.** Duplicates reviewed
  code. The upstream driver plus an OTG regulator patch is smaller and
  upstreamable.

## Follow-ups

- Stage 2 battery node: confirm charge-full-design (8800 gauge vs 9800
  stock policy) and the empty voltage; check why the gauge reports
  `CHARGE_TERM_CURRENT` 1.95 A against stock's 150 mA top-off.
- Before stage 3: through the mailbox, read-only opcodes first (0x30
  current source caps, 0x0B CC control) with a PD charger attached,
  to confirm the contract state and PDO list on mainline.
- #53 (xHCI after suspend) should be understood before the role switch
  adds another suspend path.
- `usb-host-wake` (root-hub hold) is an OpenRC script and does not run
  under systemd; it needs a unit until the role switch owns the port.
- docs/05 and the i2c5 DTS comment point at a USB section of docs/07
  that was never written; the stage 2 change writes it.
