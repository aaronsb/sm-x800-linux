# postmarketOS / mainline Linux port for the Samsung Galaxy Tab S8+ (SM-X800)
#
# Boot chain:  Samsung ABL -> uniLoader -> mainline kernel (+ our DTB, ramdisk)
# See docs/05-mainline-uniloader-boot.md for WHY it has to work this way.
#
# The build is a sequence. Each step checks what the previous one left behind
# and names the step to run when something is missing:
#
#   make check          # host tools, pmbootstrap init, dumps, harvest, apks
#   make deps           # one-time: uniLoader clone + patches, chroot toolchain
#   make dumps          # verify (ADB=1: pull) the stock partition dumps
#   make harvest        # copy the proprietary blobs out of the dumps
#   make rootfs         # pmb install; preserves the image, prints the UUIDs
#   make image          # uuids gate -> kernel -> device -> boot -> sparse
#   make flash-all      # first install: boot + userdata in ONE odin session
#   make install-tablet # later kernels: dd boot.img + apk add over ssh, reboot
#
# Variants: boot-debug (pmos.debug-shell flavor), kernel, device, boot,
# flash-help. `make help` prints the same list.
#
# NOTE: every `make flash*` target needs the device in a FRESHLY ENTERED
# download mode. A stale session fails with "FAIL! (Auth)", and a failed
# transfer wedges the session until the device is rebooted. See docs/05 §5.

SHELL       := /bin/bash
PMB         := ./pmb
PMB_CFG     := $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/pmbootstrap_v3.cfg
APORTS_ROOT := pmb-work/cache_git/pmaports
APORTS      := $(APORTS_ROOT)/device/testing
OVERLAY     := pmaports-overlay/device/testing
# Non-device packages forked from Alpine live in temp/, as in pmaports.
TEMP_OVERLAY := pmaports-overlay/temp
TEMP_PKGS   := $(notdir $(wildcard $(TEMP_OVERLAY)/*))
KPKG        := linux-postmarketos-qcom-sm8450
DPKG        := device-samsung-gts8pwifi
DEVICE      := samsung-gts8pwifi
ROOTFS_BOOT := pmb-work/chroot_rootfs_$(DEVICE)/boot
PKGS        := pmb-work/packages/edge/aarch64
UL_SRC      := reference/uniLoader
UL_CHROOT   := pmb-work/chroot_native/home/pmos/uniLoader
UL_PORT     := pmaports-overlay/uniloader-port
BUILD       := root-build/uniloader
# The combined rootfs image (pmOS_boot + pmOS_root in one GPT) lives at the
# top of root-build/, NOT under $(BUILD), see docs/05 section 8b.
COMBINED    := root-build/combined.img
STAGE       := .stage
CROSS       := aarch64-alpine-linux-musl-
# Stock boot.img values: Samsung enforces anti-rollback (download screen: AR:2)
OS_VERSION  := 12.0.0
OS_PATCH    := 2025-04

# Stock partition dumps (docs/01 step 8) and what the build derives from them.
DUMPS       := device-facts/partitions-backup
DUMP_PARTS  := boot apnhlos super
HARVEST     := root-build/stock-extract/harvest
SENSORS     := root-build/stock-extract/sensors
# Where tools/fw-manifest.tsv puts the a730_zap row (dest_dir column).
ZAP_DIR     := $(HARVEST)/qcom/sm8450/gts8pwifi
# Pre-harvest location of the same splits, still honoured by stage-fw.
ZAP_LEGACY  := root-build/stock-extract

# Package versions come from the overlay APKBUILDs, so every target that picks
# an apk picks the one this tree describes, never the newest file by mtime.
pkgfield     = $(shell sed -n 's/^$(2)=//p' $(1)/APKBUILD)
KVER        := $(call pkgfield,$(OVERLAY)/$(KPKG),pkgver)
KREL        := $(call pkgfield,$(OVERLAY)/$(KPKG),pkgrel)
DVER        := $(call pkgfield,$(OVERLAY)/$(DPKG),pkgver)
DREL        := $(call pkgfield,$(OVERLAY)/$(DPKG),pkgrel)
KERNEL_APK  := $(PKGS)/$(KPKG)-$(KVER)-r$(KREL).apk
DEVICE_APKS := $(PKGS)/$(DPKG)-$(DVER)-r$(DREL).apk \
               $(PKGS)/$(DPKG)-systemd-$(DVER)-r$(DREL).apk

# Kernel command line handed to uniLoader as blob/cmdline (see cmdline-blob).
CMDLINE_IN  := $(UL_PORT)/cmdline.in
BOOTARGS_EXTRA ?=
# FLAVOR suffixes the uniLoader binary, boot image and tar so boot-debug does
# not overwrite the normal artifacts.
FLAVOR      ?=

# install-tablet talks to the running port over ssh.
TABLET      ?= user@192.168.2.123

# tools/README "Never run two pmbootstrap operations concurrently": the kernel
# and device builds share one aports work tree and interleaved runs
# cross-write APKBUILDs. Serialise everything in this Makefile.
.NOTPARALLEL:

.PHONY: help check check-tools deps pmb-config toolchain dumps harvest \
        kernel device stage-fw cmdline-blob uniloader bootimg manifest boot \
        boot-debug rootfs uuids image install-tablet \
        flash flash-full flash-rootfs sparse flash-all flash-stay flash-help \
        restore-android device-status sync-aports sync-overlay lint clean \
        distclean dtb-dump

help: ## Show the build sequence and every target
	@echo "  BUILD SEQUENCE (each step names the previous one when it is missing):"
	@echo "    make check           host tools, pmbootstrap init, dumps, harvest, apks"
	@echo "    make deps            one-time: uniLoader clone + patches, chroot toolchain"
	@echo "    make dumps           verify the stock partition dumps (ADB=1: pull them)"
	@echo "    make harvest         copy the proprietary blobs out of the dumps"
	@echo "    make rootfs          pmb install; preserves the image, prints the UUIDs"
	@echo "    make image           uuids gate -> kernel -> device -> boot -> sparse"
	@echo "    make flash-all       first install: boot + userdata in ONE odin session"
	@echo "    make install-tablet  later kernels: dd boot.img + apk add over ssh, reboot"
	@echo ""
	@echo "  VARIANTS:"
	@echo "    make boot-debug      boot image with pmos.debug-shell (own boot-debug.img/.tar)"
	@echo "    make kernel          kernel package only (kernel + our DTB)"
	@echo "    make device          device + temp/ packages only"
	@echo "    make boot            kernel -> uniLoader -> boot.img -> flashable tar"
	@echo "    make flash-help      which odin flash flavor do I want?"
	@echo ""
	@echo "  ALL TARGETS:"
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

## ---------------------------------------------------------------------------
## Preflight
## ---------------------------------------------------------------------------

# One report of everything `make image` and its neighbours lean on. Items the
# image build itself needs fail the target; the rest print as notes with the
# target that provides them. Firmware harvest from a stock super.img needs
# lpunpack (vendor split) and an erofs reader (mount or fsck.erofs); sparse
# dumps need simg2img; DTB inspection needs dtc; flashing needs odin4; dumps
# over USB need adb.
check: ## Preflight: host tools, pmb init, uniLoader, dumps, harvest, apks (exit 1 if image cannot build)
	@rc=0; \
	echo ">> host tools needed by 'make image':"; \
	for t in mkbootimg unpack_bootimg img2simg cpio; do \
	    if command -v $$t >/dev/null; then echo "   ok   $$t"; \
	    else echo "   MISS $$t"; rc=1; fi; done; \
	echo ">> host tools for harvest / dumps / flash / inspection:"; \
	for t in lpunpack simg2img dtc adb odin4 sshpass; do \
	    command -v $$t >/dev/null && echo "   ok   $$t" || echo "   --   $$t"; done; \
	if command -v fsck.erofs >/dev/null || command -v dump.erofs >/dev/null; then \
	    echo "   ok   erofs-utils (fsck.erofs/dump.erofs)"; \
	else echo "   --   erofs-utils  (pacman -S erofs-utils)"; fi; \
	echo ">> pmbootstrap:"; \
	if test -f $(PMB_CFG) && test -d $(APORTS_ROOT); then \
	    echo "   ok   $(PMB_CFG), aports at $(APORTS_ROOT)"; \
	    d=$$($(PMB) config device 2>/dev/null); [ "$$d" = "$(DEVICE)" ] \
	        && echo "   ok   device $$d" \
	        || { echo "   MISS pmb device is '$$d', want $(DEVICE) (make pmb-config)"; rc=1; }; \
	else echo "   MISS not initialised: ./pmb init (see 'make deps')"; rc=1; fi; \
	echo ">> uniLoader ($(UL_SRC)):"; \
	if test -d $(UL_SRC); then \
	    h=$$(git -C $(UL_SRC) rev-parse HEAD 2>/dev/null); \
	    [ "$$h" = "$(UL_COMMIT)" ] && echo "   ok   at $(UL_COMMIT)" \
	        || { echo "   MISS at $$h, pinned $(UL_COMMIT) (make deps)"; rc=1; }; \
	else echo "   MISS clone absent (make deps)"; rc=1; fi; \
	echo ">> stock partition dumps ($(DUMPS)):"; \
	for p in $(DUMP_PARTS); do \
	    test -f $(DUMPS)/$$p.img && echo "   ok   $$p.img" || echo "   --   $$p.img (make dumps)"; done; \
	test -f $(DUMPS)/boot.img || { echo "   MISS boot.img is needed for the stock ramdisk (make dumps)"; rc=1; }; \
	echo ">> firmware harvest ($(HARVEST)):"; \
	if test -f $(ZAP_DIR)/a730_zap.mdt; then echo "   ok   a730_zap in the harvest tree"; \
	elif test -f $(ZAP_LEGACY)/a730_zap.mdt; then \
	    echo "   note a730_zap only at the pre-harvest path $(ZAP_LEGACY)/ (make harvest)"; \
	else \
	    echo "   MISS a730_zap: make harvest (needs $(DUMPS)/apnhlos.img, see make dumps)"; rc=1; fi; \
	test -d $(SENSORS) && echo "   ok   sensor registry configs in $(SENSORS)" \
	    || echo "   --   sensor registry configs in $(SENSORS) (make harvest)"; \
	echo ">> packages for $(KPKG) $(KVER)-r$(KREL), $(DPKG) $(DVER)-r$(DREL):"; \
	test -f $(KERNEL_APK) && echo "   ok   $(KERNEL_APK)" \
	    || echo "   --   $(KERNEL_APK) (make kernel)"; \
	for a in $(DEVICE_APKS); do test -f $$a && echo "   ok   $$a" || echo "   --   $$a (make device)"; done; \
	test -f $(COMBINED) && echo "   ok   $(COMBINED)" || echo "   --   $(COMBINED) (make rootfs)"; \
	if test $$rc -eq 0 && ! test -f $(COMBINED); then \
	    echo ">> ready for 'make boot' / 'make install-tablet'; 'make image' also needs 'make rootfs' ($(COMBINED))"; \
	elif test $$rc -eq 0; then echo ">> ready for 'make image'"; \
	else echo "!! MISS items above block 'make image'"; exit 1; fi

check-tools: check ## Alias of check (old name)

## ---------------------------------------------------------------------------
## Setup
## ---------------------------------------------------------------------------

# Every third-party component is PINNED: the kernel to the release tarball
# named by pkgver in its APKBUILD, uniLoader to the rev below. Local
# modifications are either whole in-repo files (our board port, our
# drivers) or patch files generated with tools/mkpatch, never hand-written
# diffs. The board registration (board/Kconfig, board/Makefile) travels as
# one of the patches below, like every other change to upstream files.
UL_COMMIT := 43770a04327532407194ddd3f9f35770daa01c70

# pmbootstrap wants `./pmb init` once, interactively; it refuses every other
# command (pmb config included) until its config file and work dir exist.
# The answers this tree expects:
#   work path   <this repo>/pmb-work
#   aports      <this repo>/pmb-work/cache_git/pmaports   (pmb clones it there)
#   channel     edge
#   device      samsung-gts8pwifi   (ours, from the overlay after sync-aports)
#   ui          console
deps: ## One-time setup: clone uniLoader (pinned), apply our port, install chroot toolchain
	@test -f $(PMB_CFG) && test -d $(APORTS_ROOT) || { \
	    echo "!! pmbootstrap is not initialised. Run once, then re-run 'make deps':"; \
	    echo "     ./pmb init"; \
	    echo "   answers: work path $(abspath pmb-work), channel edge,"; \
	    echo "            device $(DEVICE), ui console (see the comment above deps)"; \
	    exit 1; }
	@test -d $(UL_SRC) || { \
	    git init -q $(UL_SRC); \
	    git -C $(UL_SRC) remote add origin https://github.com/ivoszbg/uniLoader.git; \
	    git -C $(UL_SRC) fetch -q --depth 1 origin $(UL_COMMIT); \
	    git -C $(UL_SRC) checkout -q FETCH_HEAD; }
	@# our board port lives in-repo; copy it into the upstream clone
	install -Dm644 $(UL_PORT)/board/samsung/board-gts8pwifi.c \
	    $(UL_SRC)/board/samsung/board-gts8pwifi.c
	install -Dm644 $(UL_PORT)/configs/gts8pwifi_defconfig \
	    $(UL_SRC)/configs/gts8pwifi_defconfig
	@# changes to upstream files travel as git-generated patches, applied in
	@# name order (0001, 0002, ...); one that applies in reverse is already in.
	@# git -C resolves a relative patch path inside the clone, hence CURDIR.
	@for p in $(UL_PORT)/patches/*.patch; do \
	    [ -e "$$p" ] || continue; P=$(CURDIR)/$$p; \
	    if git -C $(UL_SRC) apply --check "$$P" 2>/dev/null; then \
	        git -C $(UL_SRC) apply "$$P" && echo ">> uniLoader: applied $$(basename $$p)"; \
	    elif git -C $(UL_SRC) apply --check -R "$$P" 2>/dev/null; then \
	        echo ">> uniLoader: $$(basename $$p) already applied"; \
	    else echo "!! uniLoader: $$(basename $$p) neither applies nor is applied"; exit 1; fi; \
	done
	$(MAKE) --no-print-directory toolchain

# Pin the pmb settings this tree relies on. Only corrects an existing init:
# pmb config refuses to run before `./pmb init` has created the config file.
pmb-config: ## Set pmb device/work/aports/ui to what this tree expects (after ./pmb init)
	@test -f $(PMB_CFG) || { echo "!! run ./pmb init first (see 'make deps')"; exit 1; }
	$(PMB) config work $(abspath pmb-work)
	$(PMB) config aports $(abspath $(APORTS_ROOT))
	$(PMB) config device $(DEVICE)
	$(PMB) config ui console

toolchain: ## Install the aarch64 cross toolchain into the pmb chroot
	@# pmb build --force zaps the chroot, so this is re-run by other targets
	$(PMB) chroot -- apk add build-base gcc-aarch64 binutils-aarch64 \
	    make bison flex >/dev/null

# The dumps are the builder's own stock firmware and never leave this machine
# (see .gitignore). An existing dump is never overwritten. With ADB=1 the
# missing ones are pulled from a tablet rooted on stock (docs/01 step 8):
# `adb exec-out` is `adb shell` with a binary-safe stdout, which a raw dd
# needs; the on-device sha256sum of the block device verifies the transfer.
dumps: ## Verify stock dumps boot/apnhlos/super (.sha256 sidecars); ADB=1 pulls missing ones from a rooted stock tablet
	@set -e; mkdir -p $(DUMPS); missing=0; \
	for p in $(DUMP_PARTS); do img=$(DUMPS)/$$p.img; \
	    if test -f $$img; then \
	        if test -f $$img.sha256; then \
	            (cd $(DUMPS) && sha256sum -c --quiet $$p.img.sha256) \
	                && echo "   ok   $$p.img (sha256 verified)" \
	                || { echo "!! $$p.img does not match $$p.img.sha256"; exit 1; }; \
	        else (cd $(DUMPS) && sha256sum $$p.img > $$p.img.sha256); \
	             echo "   ok   $$p.img (sha256 written)"; fi; \
	    elif [ "$(ADB)" = "1" ]; then \
	        echo ">> pulling $$p from /dev/block/by-name/$$p over adb"; \
	        adb exec-out su -c "dd if=/dev/block/by-name/$$p bs=4M 2>/dev/null" > $$img.part; \
	        want=$$(adb shell su -c "sha256sum /dev/block/by-name/$$p" | cut -d' ' -f1 | tr -d '\r'); \
	        have=$$(sha256sum $$img.part | cut -d' ' -f1); \
	        [ "$$want" = "$$have" ] || { rm -f $$img.part; echo "!! $$p: sha256 mismatch after pull"; exit 1; }; \
	        mv $$img.part $$img; echo "$$have  $$p.img" > $$img.sha256; \
	        echo "   ok   $$p.img (pulled, sha256 verified against the device)"; \
	    else echo "   MISS $$p.img"; missing=1; fi; \
	done; \
	test $$missing -eq 0 || { \
	    echo ">> missing dumps: 'make dumps ADB=1' with the tablet rooted on stock (docs/01 step 8),"; \
	    echo "   or copy an earlier backup into $(DUMPS)/"; exit 1; }

# Copies the manifest's blobs (tools/fw-manifest.tsv) out of the dumps into
# the harvest tree and the sensor registry configs out of super's vendor
# image. Both scripts need root for lpunpack and loop mounts; the results are
# handed back to the caller. Re-running rewrites the same files.
harvest: ## Harvest proprietary blobs (fw-harvest.sh) and sensor configs (sensors-from-super.sh) from the dumps
	@test -f $(DUMPS)/apnhlos.img || test -f $(DUMPS)/super.img \
	    || { echo "!! no apnhlos.img or super.img in $(DUMPS)/ (make dumps)"; exit 1; }
	@test -f $(DUMPS)/apnhlos.img \
	    || echo ">> note: apnhlos.img absent, the a730_zap row will be skipped (make dumps ADB=1)"
	sudo tools/fw-harvest.sh --from-dumps $(DUMPS) --out $(HARVEST)
	sudo chown -R $$(id -u):$$(id -g) $(HARVEST)
	@if test -f $(DUMPS)/super.img; then \
	    sudo tools/sensors-from-super.sh $(DUMPS)/super.img --out $(SENSORS) \
	        && sudo chown -R $$(id -u):$$(id -g) $(SENSORS); \
	else echo ">> note: super.img absent, sensor registry configs not staged"; fi
	@if test -f $(ZAP_DIR)/a730_zap.mdt; then echo ">> a730_zap staged in $(ZAP_DIR)"; \
	elif test -f $(ZAP_LEGACY)/a730_zap.mdt; then \
	    echo ">> WARNING: no a730_zap in the harvest tree; stage-fw keeps using $(ZAP_LEGACY)/ until apnhlos.img is dumped"; \
	else echo ">> WARNING: no a730_zap anywhere; 'make image' stops at stage-fw (make dumps ADB=1, then make harvest)"; fi

## ---------------------------------------------------------------------------
## Build
## ---------------------------------------------------------------------------

# pmb checksum rewrites the sha512sums block in the aports copy; copy the
# APKBUILD straight back so the overlay (the committed source) never lags.
kernel: sync-aports ## Build the mainline kernel package (kernel + our DTB)
	$(PMB) checksum $(KPKG) >/dev/null
	cp $(APORTS)/$(KPKG)/APKBUILD $(OVERLAY)/$(KPKG)/APKBUILD
	$(PMB) build $(KPKG) --force

# The device package is rebuilt every time (its scripts change without a
# pkgrel bump during iteration); temp/ packages only when their version moved.
device: sync-aports ## Build the device package and the temp/ packages (hexagonrpcd)
	$(PMB) checksum $(DPKG) >/dev/null
	cp $(APORTS)/$(DPKG)/APKBUILD $(OVERLAY)/$(DPKG)/APKBUILD
	$(PMB) build $(DPKG) --force
	@for p in $(TEMP_PKGS); do \
	    $(PMB) checksum $$p >/dev/null || exit 1; \
	    cp $(APORTS_ROOT)/temp/$$p/APKBUILD $(TEMP_OVERLAY)/$$p/APKBUILD; \
	    $(PMB) build $$p || exit 1; \
	done

# The zap shader is Samsung-signed and lives in NO package (proprietary,
# never committed). `make harvest` copies it out of the apnhlos dump into
# $(ZAP_DIR). The a7xx GPU needs it IN THE INITRAMFS (bind-time SQE load), so
# before every boot-image build: stage it into the rootfs chroot and
# regenerate the initramfs there. Idempotent and cheap (~8s); failing loudly
# here beats silently shipping a GPU-less boot image.
# Transitional: trees harvested before `make harvest` existed keep the splits
# directly in $(ZAP_LEGACY)/; those are used when the harvest tree has none.
stage-fw: ## Stage non-redistributable GPU firmware into the rootfs chroot initramfs
	@set -e; \
	if test -f $(ZAP_DIR)/a730_zap.mdt; then src=$(ZAP_DIR); \
	elif test -f $(ZAP_LEGACY)/a730_zap.mdt; then src=$(ZAP_LEGACY); \
	    echo ">> stage-fw: zap from the pre-harvest path $$src/ ('make harvest' populates $(ZAP_DIR))"; \
	else echo "!! a730_zap splits missing: run 'make harvest' (needs $(DUMPS)/apnhlos.img, see 'make dumps')"; exit 1; fi; \
	sudo mkdir -p pmb-work/chroot_rootfs_$(DEVICE)/lib/firmware/qcom/sm8450/gts8pwifi; \
	sudo cp $$src/a730_zap.mdt $$src/a730_zap.b00 $$src/a730_zap.b01 $$src/a730_zap.b02 \
	    pmb-work/chroot_rootfs_$(DEVICE)/lib/firmware/qcom/sm8450/gts8pwifi/
	$(PMB) chroot -r -- mkinitfs >/dev/null 2>&1
	@zcat $(ROOTFS_BOOT)/initramfs | cpio -t 2>/dev/null | grep -q a730_zap.mdt \
	    && echo ">> initramfs carries the zap" \
	    || { echo "!! zap did NOT land in the initramfs"; exit 1; }

# Read the rootfs UUIDs the way boot-deploy left them: the vendor_boot header
# cmdline in the rootfs chroot (the same source `uuids` prints). Only the
# header is read, because the DTB embedded further into that image carries
# whatever the DTS said at kernel build time.
define read_rootfs_uuids
	VB=$(ROOTFS_BOOT)/vendor_boot.img; \
	test -f $$VB || { echo "!! $$VB missing: run 'make rootfs' first"; exit 1; }; \
	rm -rf $(STAGE)/vb; mkdir -p $(STAGE)/vb; \
	CMD=$$(unpack_bootimg --boot_img $$VB --out $(STAGE)/vb | sed -n 's/^vendor command line args: //p'); \
	rm -rf $(STAGE)/vb; \
	BOOT_UUID=$$(echo "$$CMD" | grep -o 'pmos_boot_uuid=[0-9a-f-]*' | head -1 | cut -d= -f2); \
	ROOT_UUID=$$(echo "$$CMD" | grep -o 'pmos_root_uuid=[0-9a-f-]*' | head -1 | cut -d= -f2); \
	test -n "$$BOOT_UUID" && test -n "$$ROOT_UUID" \
	    || { echo "!! no pmos_*_uuid in the $$VB header cmdline"; exit 1; }
endef

# uniLoader embeds blob/cmdline and sets /chosen/bootargs from it when it is
# non-empty (an empty blob leaves the DTS bootargs in place). Content:
# $(CMDLINE_IN) with @BOOT_UUID@/@ROOT_UUID@ filled from the rootfs, plus
# `bootloader=uniloader`, plus BOOTARGS_EXTRA when set; NUL-terminated.
cmdline-blob: ## Write reference/uniLoader/blob/cmdline from cmdline.in + rootfs UUIDs + BOOTARGS_EXTRA
	@set -e; test -f $(CMDLINE_IN) || { echo "!! $(CMDLINE_IN) missing"; exit 1; }; \
	$(read_rootfs_uuids); \
	CMD=$$(sed -e '/^[[:space:]]*#/d' -e "s/@BOOT_UUID@/$$BOOT_UUID/g" -e "s/@ROOT_UUID@/$$ROOT_UUID/g" \
	    $(CMDLINE_IN) | tr '\n' ' ' | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $$//'); \
	CMD="$$CMD bootloader=uniloader"; \
	[ -z "$(strip $(BOOTARGS_EXTRA))" ] || CMD="$$CMD $(strip $(BOOTARGS_EXTRA))"; \
	mkdir -p $(UL_SRC)/blob; printf '%s\0' "$$CMD" > $(UL_SRC)/blob/cmdline; \
	echo ">> blob/cmdline: $$CMD"

uniloader: toolchain stage-fw cmdline-blob ## Embed kernel+DTB+ramdisk(+cmdline) into uniLoader
	@set -e; \
	APK=$(KERNEL_APK); \
	test -f $$APK || { echo "!! $$APK missing: run 'make kernel' (version from $(OVERLAY)/$(KPKG)/APKBUILD)"; exit 1; }; \
	echo ">> using $$APK"; \
	mkdir -p $(STAGE); rm -rf $(STAGE)/boot $(STAGE)/uniLoader$(FLAVOR) $(STAGE)/kernel-apk; \
	tar xzf "$$APK" --warning=no-unknown-keyword -C $(STAGE) boot/vmlinuz \
	    boot/dtbs/qcom/sm8450-samsung-gts8pwifi.dtb; \
	gunzip -c $(STAGE)/boot/vmlinuz > $(UL_SRC)/blob/Image; \
	cp $(STAGE)/boot/dtbs/qcom/sm8450-samsung-gts8pwifi.dtb $(UL_SRC)/blob/dtb; \
	cp $(ROOTFS_BOOT)/initramfs $(UL_SRC)/blob/ramdisk; \
	rm -f $(UL_SRC)/uniLoader $(UL_SRC)/uniLoader.gz $(UL_SRC)/uniLoader.o $(UL_SRC)/.config; \
	sudo rm -rf $(UL_CHROOT); sudo cp -r $(UL_SRC) $(UL_CHROOT); \
	sudo chown -R 12345:12345 $(UL_CHROOT); \
	$(PMB) chroot -- sh -c 'cd /home/pmos/uniLoader && \
	    make ARCH=aarch64 CROSS_COMPILE=$(CROSS) gts8pwifi_defconfig >/dev/null && \
	    make ARCH=aarch64 CROSS_COMPILE=$(CROSS) >/dev/null'; \
	sudo cp $(UL_CHROOT)/uniLoader $(STAGE)/uniLoader$(FLAVOR); \
	sudo chown $$(id -u):$$(id -g) $(STAGE)/uniLoader$(FLAVOR); \
	echo "$$APK" > $(STAGE)/kernel-apk; \
	ls -la $(STAGE)/uniLoader$(FLAVOR)

# The stock ramdisk comes out of the boot.img dump (docs/01 step 8).
bootimg: ## Package uniLoader into a flashable boot.img + tar
	@set -e; \
	mkdir -p $(BUILD); \
	test -f $(STAGE)/uniLoader$(FLAVOR) || { echo "!! $(STAGE)/uniLoader$(FLAVOR) missing: run 'make uniloader'"; exit 1; }; \
	test -f $(STAGE)/stock_ramdisk || { \
	  test -f $(DUMPS)/boot.img || { echo "!! $(DUMPS)/boot.img missing (make dumps)"; exit 1; }; \
	  unpack_bootimg --boot_img $(DUMPS)/boot.img \
	    --out $(STAGE)/stock >/dev/null; cp $(STAGE)/stock/ramdisk $(STAGE)/stock_ramdisk; }; \
	mkbootimg --header_version 4 \
	    --os_version $(OS_VERSION) --os_patch_level $(OS_PATCH) \
	    --kernel $(STAGE)/uniLoader$(FLAVOR) --ramdisk $(STAGE)/stock_ramdisk --cmdline '' \
	    -o $(BUILD)/boot$(FLAVOR).img; \
	cd $(BUILD) && tar -H ustar -cf ../pmos_uniloader_boot$(FLAVOR).tar boot$(FLAVOR).img; \
	ls -la ../pmos_uniloader_boot$(FLAVOR).tar

# The bring-up scoreboard, numbered like the docs/ phase files. Printed at the
# end of every successful boot-image build: partly celebration, partly a
# reminder of what any given flash is putting at risk.
manifest: ## Print the numbered subsystem bring-up manifest
	@printf '\n   \033[1mSM-X800 mainline — systems online\033[0m\n'
	@printf '   01 \033[32m✔\033[0m boot chain      ABL → uniLoader → mainline kernel\n'
	@printf '   02 \033[32m✔\033[0m storage         UFS root, combined-image layout\n'
	@printf '   03 \033[32m✔\033[0m input           FTS touchscreen · pogo Book Cover Keyboard\n'
	@printf '   04 \033[32m✔\033[0m wireless        WCN6855 WiFi (ath11k) · Bluetooth\n'
	@printf '   05 \033[32m✔\033[0m usb-host        VBUS sourcing (MAX77705 OTG)\n'
	@printf '   06 \033[32m✔\033[0m display         native KMS: DPU/DSI/DSC · S6TUUM1 panel · DPMS\n'
	@printf '   07 \033[32m✔\033[0m gpu             Adreno 730 · zap from apnhlos · FD730 GL ES 3.2\n'
	@printf '   08 \033[33m…\033[0m next            compositor · audio · S Pen · sensors\n\n'

boot: kernel uniloader bootimg manifest ## Full chain: kernel -> uniLoader -> flashable tar
	@echo ">> root-build/pmos_uniloader_boot$(FLAVOR).tar ready. 'make flash' in download mode."

# Same kernel apk as the last `make kernel`/`make image`, rebuilt uniLoader
# with pmos.debug-shell on the cmdline, written beside the normal artifacts.
boot-debug: ## Debug flavor: boot-debug.img + pmos_uniloader_boot-debug.tar with pmos.debug-shell
	$(MAKE) --no-print-directory uniloader bootimg FLAVOR=-debug \
	    BOOTARGS_EXTRA="pmos.debug-shell $(BOOTARGS_EXTRA)"
	@echo ">> root-build/pmos_uniloader_boot-debug.tar ready (drops to the initramfs debug shell)"

# The image stays MINIMAL (console) on purpose: Alpine's composition unit is
# the metapackage, not the baked image. The assembled daily-driver is applied
# ON DEVICE after first boot with one command:
#
#     sudo gts8pwifi-setup [plasma]
#
# which installs device-samsung-gts8pwifi-tools (our curated toolkit
# metapackage), optionally Plasma Desktop 6, and runs gts8pwifi-fw-extract
# (the zap can never be part of any image we build). See tools/README.
rootfs: sync-aports ## Rebuild the minimal (console) rootfs, preserve image, print UUIDs (DEVSUDO=1: passwordless sudo)
	$(PMB) config ui console
	@echo ">> WARNING: this regenerates the rootfs with NEW UUIDs."
	@echo ">> NO --split: userdata must hold the COMBINED image (GPT with"
	@echo ">> pmOS_boot AND pmOS_root) because uniLoader owns the real boot"
	@echo ">> partition. See docs/05 section 8b."
	$(PMB) install $(if $(PASSWORD),--password $(PASSWORD)) \
		$(if $(DEVSUDO),--add $(DPKG)-devsudo)
	@set -e; \
	SRC=pmb-work/chroot_native/home/pmos/rootfs/$(DEVICE).img; \
	echo ">> preserving $$SRC -> $(COMBINED)"; \
	echo ">> (pmb build --force DELETES it, and the kernel build needs its UUIDs)"; \
	sudo cp $$SRC $(COMBINED); \
	sudo chown $$(id -u):$$(id -g) $(COMBINED); \
	$(MAKE) --no-print-directory uuids || true

# Gate: the DTS bootargs carry the rootfs UUIDs, so a rootfs rebuilt after the
# DTS was last edited boots to the initramfs debug shell. Exit 1 on mismatch
# and print the two DTS lines to change. Once the DTS carries no UUIDs (the
# cmdline blob from cmdline-blob supplies them) this gate becomes unnecessary.
uuids: ## Gate: rootfs UUIDs (vendor_boot header) must match the DTS bootargs; exit 1 with the lines to change
	@set -e; $(read_rootfs_uuids); \
	DTS=$(OVERLAY)/$(KPKG)/sm8450-samsung-gts8pwifi.dts; \
	DB=$$(grep -o 'pmos_boot_uuid=[0-9a-f-]*' $$DTS | head -1 | cut -d= -f2); \
	DR=$$(grep -o 'pmos_root_uuid=[0-9a-f-]*' $$DTS | head -1 | cut -d= -f2); \
	echo ">> rootfs: pmos_boot_uuid=$$BOOT_UUID pmos_root_uuid=$$ROOT_UUID"; \
	echo ">> DTS:    pmos_boot_uuid=$$DB pmos_root_uuid=$$DR"; \
	if [ "$$DB" = "$$BOOT_UUID" ] && [ "$$DR" = "$$ROOT_UUID" ]; then echo ">> UUIDs match"; \
	else \
	    echo "!! UUID mismatch: the DTS bootargs must carry the rootfs values. Change in $$DTS:"; \
	    grep -n 'pmos_boot_uuid=' $$DTS | cut -d: -f1 | head -1 | sed "s/^/   line /;s/$$/: pmos_boot_uuid=$$DB -> pmos_boot_uuid=$$BOOT_UUID/"; \
	    grep -n 'pmos_root_uuid=' $$DTS | cut -d: -f1 | head -1 | sed "s/^/   line /;s/$$/: pmos_root_uuid=$$DR -> pmos_root_uuid=$$ROOT_UUID/"; \
	    echo "   sed -i 's/$$DB/$$BOOT_UUID/;s/$$DR/$$ROOT_UUID/' $$DTS"; \
	    exit 1; fi

image: uuids kernel device boot sparse ## uuids gate -> kernel -> device -> boot -> sparse userdata tar
	@echo ">> image complete: root-build/pmos_uniloader_boot.tar + root-build/pmos_userdata_sparse.tar"
	@echo ">> first install: 'make flash-all' in download mode; kernel update on a running port: 'make install-tablet'"

# Kernel update on the running port, no download mode: dd the boot image
# (boot is GPT label "boot" = sda25, device-facts/partitions-by-name.txt; the
# device scripts already address partitions by label), verify it, install the
# matching kernel and device apks so /lib/modules follows the kernel, reboot.
# Refuses when .stage/kernel-apk is not the apk the overlay APKBUILD names.
install-tablet: ## Push boot.img + apks to TABLET (user@192.168.2.123) over ssh, dd + verify, apk add, reboot (NOREBOOT=1 skips)
	@set -e; \
	have=$$(cat $(STAGE)/kernel-apk 2>/dev/null || true); \
	[ "$$have" = "$(KERNEL_APK)" ] \
	    || { echo "!! $(STAGE)/kernel-apk says '$$have', APKBUILD wants $(KERNEL_APK): run 'make image' (or 'make boot') first"; exit 1; }; \
	test -f $(BUILD)/boot.img || { echo "!! $(BUILD)/boot.img missing: run 'make boot'"; exit 1; }; \
	APKS="$(KERNEL_APK) $(DEVICE_APKS)"; \
	for a in $$APKS; do test -f $$a || { echo "!! $$a missing: run 'make device'"; exit 1; }; done; \
	for p in $(TEMP_PKGS); do \
	    v=$$(sed -n 's/^pkgver=//p' $(TEMP_OVERLAY)/$$p/APKBUILD)-r$$(sed -n 's/^pkgrel=//p' $(TEMP_OVERLAY)/$$p/APKBUILD); \
	    for a in $(PKGS)/$$p-$$v.apk $(PKGS)/$$p-systemd-$$v.apk $(PKGS)/$$p-udev-$$v.apk; do \
	        test -f $$a && APKS="$$APKS $$a" || echo ">> note: $$a not built, skipping"; done; done; \
	IMG=boot-$(KVER)-r$(KREL).img; SIZE=$$(stat -c %s $(BUILD)/boot.img); \
	NAMES=$$(for a in $$APKS; do printf '/home/user/%s ' $$(basename $$a); done); \
	echo ">> $(TABLET): $$IMG ($$SIZE bytes) + $$(echo $$APKS | wc -w) apks"; \
	scp -q $(BUILD)/boot.img $(TABLET):/home/user/$$IMG; \
	scp -q $$APKS $(TABLET):/home/user/; \
	ssh -t $(TABLET) "set -e; \
	    sudo dd if=/home/user/$$IMG of=/dev/disk/by-partlabel/boot bs=4M conv=fsync status=none; \
	    sudo cmp -n $$SIZE /home/user/$$IMG /dev/disk/by-partlabel/boot && echo '>> boot partition verified'; \
	    sudo apk add --allow-untrusted $$NAMES; \
	    $(if $(NOREBOOT),echo '>> NOREBOOT=1: not rebooting',sudo systemctl reboot)"

## ---------------------------------------------------------------------------
## Flash  (device must be in a FRESHLY ENTERED download mode)
## ---------------------------------------------------------------------------

device-status: ## Show whether the device is visible in download mode
	@lsusb | grep -i 04e8 || echo "no Samsung device on USB"
	@odin4 -l 2>/dev/null || true

flash-help: ## Which flash flavor do I want?
	@echo "  FLASH FLAVORS — pick by what you changed:"
	@echo ""
	@echo "    changed the DTS or kernel only ......... make flash        (boot, ~28 MB, fast)"
	@echo "    ...and the port is up and on the LAN ... make install-tablet (dd over ssh, no download mode)"
	@echo "    changed the rootfs / a device package .. make flash-rootfs (userdata, ~600 MB)"
	@echo "    changed both, or want a clean slate .... make flash-all    (ONE odin session)"
	@echo "    iterating and want to stay in DL mode .. make flash-stay   (flash-all + --redownload)"
	@echo "    something is badly wrong ............... make restore-android"
	@echo ""
	@echo "  WHY flash-all EXISTS: odin does not reset between partitions on its own."
	@echo "  The reboot we used to hit came from invoking odin4 TWICE. One invocation"
	@echo "  with both -a and -u writes both partitions in a single session."
	@echo ""
	@echo "  RULE: userdata must hold the COMBINED image (pmb install WITHOUT --split),"
	@echo "  because stage-1 needs a pmOS_boot AND a pmOS_root and uniLoader owns the"
	@echo "  real boot partition. See docs/05 section 8b."
	@echo ""
	@echo "  Every flash needs a FRESHLY entered download mode. A stale session fails"
	@echo "  'FAIL! (Auth)', and a failed transfer wedges the session until reboot."
	@echo "  Check with 'make device-status' — the USB device NUMBER should change"
	@echo "  after a re-entry; if it did not, the session is stale."

flash: ## [boot only] DTS/kernel changes: the usual fast iteration loop
	odin4 -a root-build/pmos_uniloader_boot.tar

flash-full: ## [boot + stock vendor_boot + vbmeta] rarely needed
	odin4 -a root-build/pmos_uniloader_ap.tar

sparse: ## Build the sparse userdata tar (odin rejects raw ext4 at ~3%)
	@set -e; \
	RAW=$(COMBINED); \
	test -f $$RAW || { echo "!! $$RAW missing: run 'make rootfs' first"; exit 1; }; \
	mkdir -p $(BUILD)/sparse; \
	echo ">> img2simg $$RAW (raw ext4 dies at ~3% with 'Fail request receive 3')"; \
	img2simg $$RAW $(BUILD)/sparse/userdata.img; \
	cd $(BUILD)/sparse && tar -H ustar -cf ../../pmos_userdata_sparse.tar userdata.img

flash-rootfs: sparse ## [userdata only] rootfs / device-package changes
	odin4 -u root-build/pmos_userdata_sparse.tar

flash-all: sparse ## [boot + userdata] ONE odin session, no reboot between
	@echo ">> single session: -a boot + -u userdata, no intermediate reboot"
	odin4 -a root-build/pmos_uniloader_boot.tar \
	      -u root-build/pmos_userdata_sparse.tar

flash-stay: sparse ## [boot + userdata] as flash-all, then RETURN to download mode
	odin4 -a root-build/pmos_uniloader_boot.tar \
	      -u root-build/pmos_userdata_sparse.tar --redownload

restore-android: ## [escape hatch] put stock Android back
	odin4 -a root-build/android_restore.tar -u root-build/vbmeta_disabled.tar

## ---------------------------------------------------------------------------
## Maintenance
## ---------------------------------------------------------------------------

sync-aports: ## Copy our packages from the repo into the live pmaports tree
	@mkdir -p $(APORTS) $(APORTS_ROOT)/temp
	cp -r $(OVERLAY)/$(KPKG) $(APORTS)/
	cp -r $(OVERLAY)/$(DPKG) $(APORTS)/
	@for p in $(TEMP_PKGS); do \
	    rm -rf $(APORTS_ROOT)/temp/$$p; \
	    cp -r $(TEMP_OVERLAY)/$$p $(APORTS_ROOT)/temp/; done

sync-overlay: ## Copy packages OUT of the live pmaports tree back into the repo
	cp -r $(APORTS)/$(KPKG) $(OVERLAY)/
	cp -r $(APORTS)/$(DPKG) $(OVERLAY)/
	@for p in $(TEMP_PKGS); do cp -r $(APORTS_ROOT)/temp/$$p $(TEMP_OVERLAY)/; done
	cp $(UL_SRC)/board/samsung/board-gts8pwifi.c \
	   $(UL_PORT)/board/samsung/
	cp $(UL_SRC)/configs/gts8pwifi_defconfig \
	   $(UL_PORT)/configs/

lint: ## Validate packaging + DTS bracket balance (full DTS check = `make kernel`)
	@echo "== APKBUILD shell syntax =="
	@for f in $(OVERLAY)/*/APKBUILD $(TEMP_OVERLAY)/*/APKBUILD; do bash -n $$f && echo "  ok: $$f"; done
	@echo "== deviceinfo shell syntax =="
	@bash -n $(OVERLAY)/$(DPKG)/deviceinfo && echo "  ok: deviceinfo"
	@echo "== DTS sanity =="
	@# The DTS #includes sm8450.dtsi and dt-bindings headers that only exist
	@# inside the kernel tree, so it CANNOT be compiled standalone. The real
	@# syntax check is the kernel build (`make kernel`), which compiles the dtb.
	@# Here we only catch the cheap structural mistakes.
	@f=$(OVERLAY)/$(KPKG)/sm8450-samsung-gts8pwifi.dts; \
	 ob=$$(tr -cd '{' < $$f | wc -c); cb=$$(tr -cd '}' < $$f | wc -c); \
	 if [ "$$ob" = "$$cb" ]; then echo "  ok: braces balanced ($$ob)"; \
	 else echo "  FAIL: brace mismatch ($$ob open vs $$cb close)"; exit 1; fi; \
	 grep -q 'compatible = "samsung,gts8pwifi"' $$f \
	   && echo "  ok: compatible present" || { echo "  FAIL: compatible missing"; exit 1; }
	@# A stray '*/' inside a comment silently ENDS that comment, and the rest
	@# of the prose then parses as device tree. This has bitten us twice now,
	@# both times from pasting a shell glob like /sys/.../<star>/file into a
	@# comment. Catch it here instead of 3 minutes into a kernel build.
	@f=$(OVERLAY)/$(KPKG)/sm8450-samsung-gts8pwifi.dts; \
	 awk '/\/\*/{c=1} c&&/\*\//{n=gsub(/\*\//,"&"); if(n>1||/[^ \t].*\*\/.+/){ \
	   if ($$0 !~ /^[ \t]*\*\/[ \t]*$$/ && $$0 !~ /\*\/[ \t]*$$/) \
	     {print "  FAIL: stray */ mid-line at line " NR ": " $$0; bad=1}} c=0} \
	   END{exit bad?1:0}' $$f \
	   && echo "  ok: no stray */ inside comments" \
	   || { echo "  (a comment is closed early — that text will parse as DTS)"; exit 1; }
	@echo "  note: authoritative DTS validation is 'make kernel' (compiles the dtb)"

dtb-dump: ## Decompile the DTB of the kernel apk the APKBUILD names (inspect what the kernel sees)
	@test -f $(KERNEL_APK) || { echo "!! $(KERNEL_APK) missing: run 'make kernel'"; exit 1; }; \
	rm -rf $(STAGE)/dump; mkdir -p $(STAGE)/dump; \
	tar xzf "$(KERNEL_APK)" -C $(STAGE)/dump boot/dtbs/qcom/sm8450-samsung-gts8pwifi.dtb; \
	dtc -I dtb -O dts $(STAGE)/dump/boot/dtbs/qcom/sm8450-samsung-gts8pwifi.dtb

clean: ## Remove staged build artifacts
	rm -rf $(STAGE) $(BUILD)

distclean: clean ## Also drop flashable tars
	rm -f root-build/pmos_uniloader*.tar root-build/pmos_userdata_sparse.tar
