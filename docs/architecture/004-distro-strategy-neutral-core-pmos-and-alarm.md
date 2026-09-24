---
status: Proposed
date: 2026-09-23
deciders:
  - aaronsb
  - claude
related:
  - docs/architecture/003-max77705-charger-gauge-pd-ownership.md
  - https://github.com/dotarchy/dotfiles-cli
  - https://github.com/dotarchy/dotfiles
---

# ADR-004: A distro-neutral device core with postmarketOS and Arch Linux ARM as build targets, a self-hosted package snapshot, and convenience profiles kept out of the base

## Context

The port builds one postmarketOS image. pmbootstrap builds the kernel
and device packages from `pmaports-overlay/`, installs a console rootfs
(`pmb config ui console`, `Makefile:438`), and the Makefile wraps the
result in uniLoader, a Samsung header-v4 boot.img and an Odin tar. The
Makefile calls pmbootstrap 16 times. The image is minimal on purpose;
the one convenience is on-device composition: `gts8pwifi-setup plasma`
runs `apk add postmarketos-ui-plasma-desktop`
(`device-samsung-gts8pwifi/setup.sh:22-24`).

The operator is an Arch user and prefers Arch Linux ARM (ALARM) for
the tablet. Two further wishes shape the decision:

- **A comfortable console.** zsh, oh-my-posh and Nerd Fonts on the VT.
  The kernel console (fbcon) draws PSF fonts of at most 512 glyphs and
  cannot show Nerd Font glyphs. The operator's AUR package `mlterm-fb`
  (mlterm built for the framebuffer) renders them, has an on-screen
  keyboard and rotation, and is packaged for x86_64 only. kmscon 10.0
  also renders them but takes over DRM, which collides with
  `console-blank.sh` (it unbinds fbcon and zeroes `/dev/fb0`), and DPMS
  off hangs this tablet (#41).
- **Steam.** On aarch64 Steam and its games run under FEX-Emu with a
  glibc host, and Proton needs Vulkan. postmarketOS is Alpine, musl;
  ALARM is glibc. Mesa's turnip supports the Adreno 730 upstream; this
  port has verified only OpenGL ES 3.2 through freedreno. Whether
  Steam is usable on 8 GB of RAM and this SoC's thermals is unknown.

The operator's dotarchy organisation already carries the user layer:
`dotarchy/dotfiles` publishes `com.bockelie.dotfiles` (zsh +
oh-my-posh, an mlterm console, tmux, nvim, Claude Code settings) for
the `dotfiles` CLI (`dotarchy/dotfiles-cli`, v0.8.6), which deploys a
store as symlinks and ships only an x86_64-linux binary.

Findings from the research pass (2026-09-23):

- **ALARM is current**: mesa 26.2.3, Plasma 6.7.5, systemd 261.3,
  glibc 2.43, gcc 16.1.1 on the mirror. Its maintainer team is small
  and it has stalled before. The unofficial Arch Linux Ports aarch64
  repository (ARMv8.2+, which this SoC meets) is a fallback.
- **ALARM has no dated archive.** The only public snapshot archive
  (tardis.tiny-vps.com/aarm) was disabled on 2026-06-02; the official
  mirror serves only the current state and a `-latest` rootfs tarball.
  A reproducible ALARM build must keep its own snapshot.
- **Porting is mostly packaging.** The kernel is v7.2 plus a patch
  stack, a DTS, staged C files and config fragments; the device
  package is files. What is not packaging: the initramfs (pmOS
  mkinitfs with `pmos_*` cmdline tokens and subpartition root
  discovery vs mkinitcpio), rootfs creation (pmbootstrap vs pacstrap),
  three packages Arch lacks or builds differently (hexagonrpcd with
  our 7 patches, libssc, iio-sensor-proxy with SSC support), and the
  defaults postmarketos-base provides.
- **The nested GPT** (pmOS_boot and pmOS_root inside userdata, docs/05
  §8b) exists only for pmOS's initramfs; an ALARM root can be a flat
  ext4 on userdata found by `root=PARTLABEL=userdata`.

The port is for one device. The builder does not need to generalise to
other tablets.

## Decision

### 1. A distro-neutral device core

Restructure the repository so one core feeds thin per-distro recipes:

- **Kernel:** the upstream tarball pin, the patch stack, the DTS, the
  staged drivers and the config fragments, independent of APKBUILD.
- **Device files:** a `files/` tree with an install manifest (systemd
  units and presets, udev rules, UCM and topology, console-blank,
  folio-state, scripts). APKBUILD and PKGBUILD install the same tree.
- **Firmware:** the existing harvest tools and their manifest.
- **Boot image tool:** today's `cmdline-blob`, `uniloader` and
  `bootimg` targets, parameterised by `INITRAMFS=` and `CMDLINE=`
  instead of reading pmOS vendor_boot UUIDs.
- **One version manifest** that both recipe sets read, so a kernel or
  device bump is one edit.

The first step is a refactor with a test: `make image` produces the
same pmOS output before and after.

### 2. Two targets, pmOS first

- **postmarketOS stays the reference target** until ALARM boots and
  runs the same test plans. It keeps the upstreaming path (docs/06).
- **Arch Linux ARM is the second target**, built in this repository
  for this device only:
  1. `make alarm-snapshot`, the only online step: resolve a committed
     `alarm/packages.lock` of exact versions, download them with their
     signatures and the ALARM keyring, verify, build a local repo with
     `repo-add`, record a sha256 manifest. The snapshot lives outside
     git (a release asset or a local cache); the lock and manifest are
     committed. A bump is re-snapshot, diff, review, commit.
  2. `make alarm-pkgs`: our packages built in a clean aarch64 chroot
     on the x86 Arch host (qemu-user-static binfmt, systemd-nspawn)
     against the snapshot only: hexagonrpcd, libssc,
     iio-sensor-proxy-ssc, folio-state, the device package. The kernel
     cross-builds. `SOURCE_DATE_EPOCH` is set.
  3. `make alarm-rootfs`: `pacstrap` from the snapshot and our local
     repo, an mkinitcpio hook that carries the GPU zap and SQE firmware
     (the `stage-fw` equivalent), a fixed user, fstab, empty
     machine-id.
  4. `make alarm-image`: a flat ext4 userdata with fixed UUIDs, the
     boot image from the neutral tool with `root=PARTLABEL=userdata`,
     and the same sparse Odin tar.
- Kernel and initramfs changes are tested on the tablet on both
  targets; device-file changes on the reference target, with the
  second checked at its next build.

### 3. Convenience profiles, outside the base

- Profiles are metapackages in their own overlay directory, e.g.
  `profiles/gts8pwifi-profile-{comfy,plasma,plasma-mobile,gaming}`,
  each with a `profiles/<name>.list` mapped to per-distro package
  names. Profiles depend on the device package, never the reverse.
- `make image PROFILE=<name>` adds one at build time;
  `gts8pwifi-setup <name>` installs the same package on the device.
  With no `PROFILE` the image is unchanged.
- **The comfy console:** mlterm-fb on tty1 with a Nerd Font at about
  28 to 32 px (roughly 160 to 175 columns on the 2800x1752 panel),
  zsh as the login shell, oh-my-posh. fbcon with buffyboard stays the
  minimal and rescue console. kmscon waits for a blanking design that
  does not rely on unbinding fbcon.

### 4. The user layer comes from dotarchy

- This repository owns the system layer: programs, fonts, services,
  the user account. dotarchy owns the user layer: `dotfiles-cli`
  deploys a registry configuration (`com.bockelie.dotfiles` for the
  operator) into the home directory, the same on both targets.
- `dotfiles-cli` is consumed at a pinned release with a verified hash,
  recorded in the snapshot manifest. A static musl `aarch64-linux`
  release asset in dotarchy/dotfiles-cli would serve both targets; until
  it exists, this repository packages the CLI from a pinned tag.
- Tablet-specific settings (mlterm font size, rotation) belong to the
  operator's store, not to a new registry entry; registry entries carry
  no profiles or variants.

### 5. Steam is a goal for the ALARM target, gated on evidence

A `gaming` profile (FEX-Emu with an x86 rootfs, Steam, turnip Vulkan)
is in scope for ALARM only, after `vulkaninfo` shows turnip on the A730
and a FEX smoke test runs. It is not a reason to delay the ALARM
bring-up or to change the base.

## Consequences

### Positive

- The operator's own distribution and tools (pacman, the AUR, their
  AUR packages, dotarchy) run on the tablet, and Steam becomes
  possible.
- The neutral core makes each piece of the device explicit: what is
  kernel, what is device policy, what is firmware, what is boot.
- Profiles give a comfortable image in one build flag without touching
  the base or its test plans.
- The ALARM build is reproducible despite a rolling release with no
  archive.

### Negative

- Two recipe sets and two images to keep working; kernel and initramfs
  changes need two hardware tests.
- The snapshot is ours to keep: a missed snapshot cannot be rebuilt
  later because ALARM deletes superseded packages, and old snapshots
  depend on a pinned keyring.
- ALARM's small maintainer team is a dependency the project does not
  control.
- About 2 to 4 part-time weeks to the first ALARM boot, most of it
  initramfs and root discovery on hardware (estimate), plus 2 to 3 days
  for the snapshot tooling.
- There is no CI today; two targets make it more pressing.

### Neutral

- Upstreaming stays through pmOS: the device and kernel packages keep
  their pmaports shape.
- The Samsung boot chain (uniLoader, the stock ramdisk, header-v4
  boot.img, Odin) is the same for both targets.

## Alternatives Considered

- **pmOS only.** The least work and the upstream path, but musl rules
  out Steam through FEX, and the operator's tools and packages are
  Arch's. Kept as the reference, not as the only target.
- **Switch to ALARM and retire pmOS.** Loses the working, tested image
  during the bring-up and the upstreaming path. Rejected for now;
  whether pmOS is retired after ALARM boots is an open question.
- **Debian/Mobian.** debos and real device support, but a third
  ecosystem with no gain for an Arch user. Rejected.
- **Fedora.** Adopting kmscon as its VT console, but no custom-device
  flow. Rejected.
- **Unpinned ALARM builds from the live mirror or the `-latest`
  tarball.** Simple and irreproducible: the same build a week apart
  differs. Rejected.
- **Conveniences in the base image.** Every image carries them and the
  base test plans grow. Rejected in favour of profiles.

## Amendment, 2026-09-24

Changes to the base since the draft, and what they mean for this
decision:

- **The USB gadget is in the base image.** The device package (#60)
  now carries a configfs gadget with NCM ethernet, ACM serial and MTP
  of `~/Shared` through umtprd. It is base, not a profile, on both
  targets. umtprd is not in the ALARM repositories, so it joins
  hexagonrpcd, libssc and iio-sensor-proxy-ssc among the packages
  `make alarm-pkgs` builds.
- **console-blank is console-only.** It blanks by drawing a black
  frame and handles the power key and lid itself. Under Plasma, KWin
  and powerdevil own all three. The device package must stand
  console-blank down whenever a display manager or graphical session
  is enabled, on both targets. The `plasma` profile depends on that
  change.
- **On-device composition is exercised.** `apk add
  postmarketos-ui-plasma-desktop` on a running tablet is the first real
  use of the on-device path, and the evidence for question 4.
- **Sequencing, proposed.** The 7.3 kernel bump (#11) rebases the whole patch
  stack; the neutral-core refactor moves it. The bump lands first, so
  the refactor's byte-identical `make image` test runs against a
  settled kernel.

## Open questions

1. Where do snapshots live: GitHub release assets, a local cache, or
   both?
2. How often is the snapshot bumped?
3. Is a flat userdata root acceptable for ALARM (it cannot share the
   partition layout with the pmOS image)?
4. Are profiles baked into images at build time, or does on-device
   composition stay the rule with build time as the exception?
5. Does pmOS stay long term once ALARM boots, or retire?
6. Does `mlterm-fb` (AUR) gain `aarch64`, and dotfiles-cli an aarch64
   release asset?
7. Is the USB gadget with MTP part of the ALARM base, which means
   packaging umtprd? (Recommended: yes, for parity with pmOS.)
8. How does console-blank detect a graphical setup: an enabled display
   manager, `graphical.target` as the default, or a flag the profile
   sets?
9. Is build-only CI (kernel, device packages, image) part of this
   decision or a separate issue?

## Follow-ups

- `vulkaninfo` with turnip on the current pmOS image
  (`mesa-vulkan-freedreno`), the first evidence for the Steam goal.
- The neutral-core refactor with the byte-identical `make image` test.
- Check whether Arch Linux Ports keeps dated snapshots, as a second
  source for the lock.
- Test Plasma on the pmOS image: display, rotation, touch and pen,
  the folio keyboard, VT switching, suspend and lid under logind.
