---
status: Proposed
date: 2026-09-21
deciders:
  - aaronsb
  - claude
related:
  - https://github.com/aaronsb/sm-x800-linux/issues/27
---

# ADR-001: Camera stack: mainline CAMSS raw path, V4L2 sensor and lens subdevices, processing in userspace

## Context

The Tab S8+ has three cameras: a Hynix Hi1337 rear main with a DW9808 VCM
autofocus lens and an EEPROM, a Hynix Hi847 rear ultrawide, and a Hi1337
front. None of them work on the mainline port, and the stack that drives
them on stock Android does not carry over. Stock runs Qualcomm's closed
CAMX HAL over a downstream camera kernel driver, with the ISP work split
between the VFE hardware and the ICP firmware in the vendor partition
(`CAMERA_ICP`). Each layer assumes the others, and all of them assume the
downstream kernel.

Mainline has a different shape. The Qualcomm CAMSS driver exposes the CSI
receive chain (CSIPHY, CSID, VFE) and delivers raw Bayer frames on V4L2
video nodes through the VFE's RDI path; it does not drive the VFE's image
processing pipeline. Sensors are ordinary V4L2 subdevice drivers, and
libcamera supplies image processing in userspace for devices whose ISP has
no kernel driver. SM8450 is not in CAMSS upstream. Its blocks are
csiphy-v2.1.0, csid680 and vfe680/vfe-lite680. Mainline 7.2 already drives
csid680 and vfe680 for the X1E80100 (camss-csid-680.c, camss-vfe-680.c), so
the SM8450 work is a SoC resource table, a CAMSS_8450 version and the
csiphy-v2.1.0 lane setup, checked against the downstream source. Samsung's
GPL 5.10 kernel source for the SM-X800 carries the downstream driver for
these blocks and serves as the register reference. The Hi847 has an ACPI-only driver in mainline;
the Hi1337 and DW9808 have out-of-tree drivers in the Tab S9 ports
(nacht20-de/gts9wifi-fedora, `kernel/files/hi1337_gts9u.c` and
`dw9808_vcm.c`), which run the same sensors on the same SoC family.

Board facts from the stock device tree, stated once here. The rear main
and ultrawide sensors sit on CCI0 and the front sensor on CCI1. The
autofocus actuator and the rear EEPROM sit on the GENI I2C controller
i2c2, which the DTS does not yet enable. Sensor rails are external LDOs
switched by TLMM 107, 109 and 25, with TLMM 117 shared between cameras.
Resets are TLMM 120, 106 and 24. MCLKs are TLMM 101, 103 and 104, driven
from camcc.

Issue #27 tracks the work. A search on 2026-09-21 of mainline, the WIP
C-PHY series, Qualcomm's kernel-topics staging repo and the sm8450-mainline
org found no SM8450 CAMSS support in progress anywhere.

## Decision

Cameras are exposed through the mainline CAMSS driver's raw path. CSIPHY,
CSID and VFE deliver Bayer frames on V4L2 video nodes, and no ISP runs in
the kernel.

Each sensor is a V4L2 subdevice driver exposing the standard controls:
exposure, analog and digital gain, vblank and hblank for frame rate, and
test pattern. The autofocus lens is its own subdevice, a DW9808 VCM driver,
bound to the rear sensor through the async notifier. The firmware-side
camera stacks are out of scope: the CAMX HAL, the ICP firmware and the
downstream camera kernel driver are not run. The downstream GPL source is
used only as a register reference.

Image processing lives in userspace and is replaceable. libcamera's
software ISP pipeline is the default, with a sensor helper for the Hynix
sensors. Raw frames stay reachable with plain V4L2 tools regardless of what
sits above them.

Sequencing:

1. CAMSS SM8450 support: csiphy-v2.1.0, csid680, vfe680 and vfe-lite680
   tables and the SoC resource description, against the downstream driver.
2. Hi847 ultrawide: convert the ACPI-only mainline driver to OF with
   regulator and reset sequencing on the hi846 pattern.
3. Hi1337 rear and front, and the DW9808 lens: port the Tab S9 out-of-tree
   drivers, and enable i2c2 for the lens and EEPROM.
4. libcamera: pipeline configuration and the Hynix sensor helper.

Reversibility: expensive. The decision is reversible until the first frame
lands on a V4L2 node; once the CAMSS tables are written and the sensor
drivers depend on them, changing course means discarding that work. Step 1
delivering a frame is the milestone that graduates it.

## Consequences

### Positive

- Every kernel piece has an upstream home: CAMSS tables, an OF conversion
  of an existing driver, two new sensor drivers and a lens driver are all
  the kind of change mainline takes, which fits the project's upstreaming
  aim (docs/06-upstreaming.md).
- The kernel path is simple to verify. A frame on a video node, dumped with
  `v4l2-ctl`, proves the receive chain and the sensor independently of any
  processing.
- The processing layer can change without touching the kernel. libcamera's
  software ISP can be replaced, tuned or bypassed, and applications that
  speak V4L2 keep working.
- No closed or firmware components are needed, so the camera does not add
  to the firmware harvest and does not depend on a vendor partition.

### Negative

- The SM8450 CAMSS resource table and csiphy-v2.1.0 setup have to be
  written from the downstream source by this project, and the C-PHY series
  in flight may change the driver underneath.
- Image quality and CPU cost are set by a software ISP. The VFE's
  processing hardware and the ICP go unused, so stock's image quality is
  not a target and battery cost per frame is higher.
- Three drivers and a DTS camera block carry cross-dependencies: a sensor
  cannot be tested until CAMSS delivers frames, and the lens cannot be
  tested until i2c2 is enabled and the rear sensor probes.
- Porting the Hi1337 driver from a vendor tree means bringing it to
  mainline standards before it can go upstream.

### Neutral

- Register-level knowledge of the downstream driver is needed but its code
  is not reused, which keeps the licensing situation the same as the rest
  of the port.
- The camera stack follows the Tab S9 ports closely, so their fixes apply
  here and this port's fixes apply there.

## Alternatives Considered

- Downstream camera kernel driver plus CAMX HAL on the mainline kernel.
  Rejected: the downstream driver targets a 5.10 GKI ABI and does not
  build against 7.2, the HAL is closed, both depend on the ICP firmware,
  and none of it has a path upstream.
- ISP in the kernel on the VFE's processing path. Rejected: mainline CAMSS
  exposes only the RDI raw path for these SoCs, and the VFE processing
  pipeline has no mainline driver. Writing one is a larger project than
  the whole camera stack and would still need tuning data that only the
  vendor holds.
- Waiting for someone else to post SM8450 CAMSS. Rejected: the 2026-09-21
  search found nothing in mainline, the WIP C-PHY series, Qualcomm's
  kernel-topics staging repo or the sm8450-mainline org, and the Tab S9
  ports are on SM8550 and do not need it.
- USB or PipeWire virtual camera hacks. Rejected: they give applications a
  camera device without giving them the sensors. There is no frame source
  to virtualize.
