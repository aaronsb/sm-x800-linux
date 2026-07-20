# postmarketOS / mainline Linux port for the Samsung Galaxy Tab S8+ (SM-X800)
#
# Boot chain:  Samsung ABL -> uniLoader -> mainline kernel (+ our DTB, ramdisk)
# See docs/05-mainline-uniloader-boot.md for WHY it has to work this way.
#
# Quick start:
#   make deps        # one-time: uniLoader clone + chroot toolchain
#   make boot        # kernel -> uniLoader -> boot.img -> flashable tar
#   make flash       # odin4 the boot image (device must be in download mode)
#
# NOTE: every `make flash*` target needs the device in a FRESHLY ENTERED
# download mode. A stale session fails with "FAIL! (Auth)". See docs/05 §5.

SHELL       := /bin/bash
PMB         := ./pmb
APORTS      := pmb-work/cache_git/pmaports/device/testing
OVERLAY     := pmaports-overlay/device/testing
KPKG        := linux-postmarketos-qcom-sm8450
DPKG        := device-samsung-gts8pwifi
DEVICE      := samsung-gts8pwifi
ROOTFS_BOOT := pmb-work/chroot_rootfs_$(DEVICE)/boot
UL_SRC      := reference/uniLoader
UL_CHROOT   := pmb-work/chroot_native/home/pmos/uniLoader
BUILD       := root-build/uniloader
# The combined rootfs image (pmOS_boot + pmOS_root in one GPT) lives at the
# top of root-build/, NOT under $(BUILD) — see docs/05 section 8b.
COMBINED    := root-build/combined.img
STAGE       := .stage
CROSS       := aarch64-alpine-linux-musl-
# Stock boot.img values — Samsung enforces anti-rollback (download screen: AR:2)
OS_VERSION  := 12.0.0
OS_PATCH    := 2025-04

.PHONY: help deps kernel uniloader bootimg boot flash flash-full flash-rootfs \
        sparse flash-all flash-stay restore-android sync-aports uuids \
        rootfs sync-overlay lint clean distclean device-status dtb-dump

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

## ---------------------------------------------------------------------------
## Setup
## ---------------------------------------------------------------------------

deps: ## One-time setup: clone uniLoader, install chroot toolchain
	@test -d $(UL_SRC) || git clone --depth 1 \
	    https://github.com/ivoszbg/uniLoader.git $(UL_SRC)
	@# our board port lives in-repo; copy it into the upstream clone
	install -Dm644 pmaports-overlay/uniloader-port/board/samsung/board-gts8pwifi.c \
	    $(UL_SRC)/board/samsung/board-gts8pwifi.c
	install -Dm644 pmaports-overlay/uniloader-port/configs/gts8pwifi_defconfig \
	    $(UL_SRC)/configs/gts8pwifi_defconfig
	@grep -q GTS8PWIFI $(UL_SRC)/board/Makefile || \
	    echo 'lib-$$(CONFIG_SAMSUNG_GTS8PWIFI) += samsung/board-gts8pwifi.o' \
	      >> $(UL_SRC)/board/Makefile
	@echo ">> Ensure board/Kconfig has SAMSUNG_GTS8PWIFI (see uniloader-port/REGISTRATION.txt)"
	$(MAKE) toolchain

toolchain: ## Install the aarch64 cross toolchain into the pmb chroot
	@# pmb build --force zaps the chroot, so this is re-run by other targets
	$(PMB) chroot -- apk add build-base gcc-aarch64 binutils-aarch64 \
	    make bison flex >/dev/null 2>&1 || true

## ---------------------------------------------------------------------------
## Build
## ---------------------------------------------------------------------------

kernel: sync-aports ## Build the mainline kernel package (kernel + our DTB)
	$(PMB) checksum $(KPKG) >/dev/null
	$(PMB) build $(KPKG) --force

uniloader: toolchain ## Embed kernel+DTB+ramdisk into uniLoader
	@set -e; \
	APK=$$(ls -t pmb-work/packages/edge/aarch64/$(KPKG)-*.apk | head -1); \
	echo ">> using $$APK"; \
	rm -rf $(STAGE); mkdir -p $(STAGE); \
	tar xzf "$$APK" -C $(STAGE) boot/vmlinuz \
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
	sudo cp $(UL_CHROOT)/uniLoader $(STAGE)/uniLoader; \
	sudo chown $$(id -u):$$(id -g) $(STAGE)/uniLoader; \
	ls -la $(STAGE)/uniLoader

bootimg: ## Package uniLoader into a flashable boot.img + tar
	@set -e; \
	mkdir -p $(BUILD); \
	test -f $(STAGE)/stock_ramdisk || { \
	  unpack_bootimg --boot_img device-facts/partitions-backup/boot.img \
	    --out $(STAGE)/stock >/dev/null; cp $(STAGE)/stock/ramdisk $(STAGE)/stock_ramdisk; }; \
	mkbootimg --header_version 4 \
	    --os_version $(OS_VERSION) --os_patch_level $(OS_PATCH) \
	    --kernel $(STAGE)/uniLoader --ramdisk $(STAGE)/stock_ramdisk --cmdline '' \
	    -o $(BUILD)/boot.img; \
	cd $(BUILD) && tar -H ustar -cf ../pmos_uniloader_boot.tar boot.img; \
	ls -la ../pmos_uniloader_boot.tar

boot: kernel uniloader bootimg ## Full chain: kernel -> uniLoader -> flashable tar
	@echo ">> root-build/pmos_uniloader_boot.tar ready. 'make flash' in download mode."

rootfs: ## Rebuild the pmOS rootfs, preserve the image, print the new UUIDs
	@echo ">> WARNING: this regenerates the rootfs with NEW UUIDs."
	@echo ">> NO --split: userdata must hold the COMBINED image (GPT with"
	@echo ">> pmOS_boot AND pmOS_root) because uniLoader owns the real boot"
	@echo ">> partition. See docs/05 section 8b."
	$(PMB) install --password 147147
	@set -e; \
	SRC=pmb-work/chroot_native/home/pmos/rootfs/$(DEVICE).img; \
	echo ">> preserving $$SRC -> $(COMBINED)"; \
	echo ">> (pmb build --force DELETES it, and the kernel build needs its UUIDs)"; \
	sudo cp $$SRC $(COMBINED); \
	sudo chown $$(id -u):$$(id -g) $(COMBINED); \
	$(MAKE) --no-print-directory uuids

uuids: ## Print the rootfs UUIDs that must be baked into the DTS bootargs
	@set -e; \
	VB=pmb-work/chroot_rootfs_$(DEVICE)/boot/vendor_boot.img; \
	echo ">> UUIDs from $$VB — these MUST match /chosen/bootargs in the DTS:"; \
	sudo strings $$VB | grep -o 'pmos_boot_uuid=[0-9a-f-]*' | head -1; \
	sudo strings $$VB | grep -o 'pmos_root_uuid=[0-9a-f-]*' | head -1; \
	echo ">> current DTS says:"; \
	grep -o 'pmos_boot_uuid=[0-9a-f-]*' $(OVERLAY)/$(KPKG)/sm8450-samsung-gts8pwifi.dts; \
	grep -o 'pmos_root_uuid=[0-9a-f-]*' $(OVERLAY)/$(KPKG)/sm8450-samsung-gts8pwifi.dts

## ---------------------------------------------------------------------------
## Flash  (device must be in a FRESHLY ENTERED download mode)
## ---------------------------------------------------------------------------

device-status: ## Show whether the device is visible in download mode
	@lsusb | grep -i 04e8 || echo "no Samsung device on USB"
	@odin4 -l 2>/dev/null || true

flash: ## Flash boot.img only (the usual iteration loop)
	odin4 -a root-build/pmos_uniloader_boot.tar

flash-full: ## Flash boot + STOCK vendor_boot + vbmeta
	odin4 -a root-build/pmos_uniloader_ap.tar

sparse: ## Build the sparse userdata tar (odin rejects raw ext4 at ~3%)
	@set -e; \
	RAW=$(COMBINED); \
	test -f $$RAW || { echo "!! $$RAW missing — run 'make rootfs' first"; exit 1; }; \
	mkdir -p $(BUILD)/sparse; \
	echo ">> img2simg $$RAW (raw ext4 dies at ~3% with 'Fail request receive 3')"; \
	img2simg $$RAW $(BUILD)/sparse/userdata.img; \
	cd $(BUILD)/sparse && tar -H ustar -cf ../../pmos_userdata_sparse.tar userdata.img

flash-rootfs: sparse ## Flash the rootfs to userdata (MUST be a sparse image)
	odin4 -u root-build/pmos_userdata_sparse.tar

flash-all: sparse ## Flash boot AND userdata in ONE odin session (no reboot between)
	@echo ">> single session: -a boot + -u userdata, no intermediate reboot"
	odin4 -a root-build/pmos_uniloader_boot.tar \
	      -u root-build/pmos_userdata_sparse.tar

flash-stay: sparse ## Like flash-all, but come back up in download mode for the next round
	odin4 -a root-build/pmos_uniloader_boot.tar \
	      -u root-build/pmos_userdata_sparse.tar --redownload

restore-android: ## Put stock/KernelSU Android back (recovery escape hatch)
	odin4 -a root-build/android_restore.tar -u root-build/vbmeta_disabled.tar

## ---------------------------------------------------------------------------
## Maintenance
## ---------------------------------------------------------------------------

sync-aports: ## Copy our packages from the repo into the live pmaports tree
	@mkdir -p $(APORTS)
	cp -r $(OVERLAY)/$(KPKG) $(APORTS)/
	cp -r $(OVERLAY)/$(DPKG) $(APORTS)/

sync-overlay: ## Copy packages OUT of the live pmaports tree back into the repo
	cp -r $(APORTS)/$(KPKG) $(OVERLAY)/
	cp -r $(APORTS)/$(DPKG) $(OVERLAY)/
	cp $(UL_SRC)/board/samsung/board-gts8pwifi.c \
	   pmaports-overlay/uniloader-port/board/samsung/
	cp $(UL_SRC)/configs/gts8pwifi_defconfig \
	   pmaports-overlay/uniloader-port/configs/

lint: ## Validate packaging + DTS bracket balance (full DTS check = `make kernel`)
	@echo "== APKBUILD shell syntax =="
	@for f in $(OVERLAY)/*/APKBUILD; do bash -n $$f && echo "  ok: $$f"; done
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

dtb-dump: ## Decompile the DTB we last built (inspect what the kernel sees)
	@APK=$$(ls -t pmb-work/packages/edge/aarch64/$(KPKG)-*.apk | head -1); \
	rm -rf $(STAGE)/dump; mkdir -p $(STAGE)/dump; \
	tar xzf "$$APK" -C $(STAGE)/dump boot/dtbs/qcom/sm8450-samsung-gts8pwifi.dtb; \
	dtc -I dtb -O dts $(STAGE)/dump/boot/dtbs/qcom/sm8450-samsung-gts8pwifi.dtb

clean: ## Remove staged build artifacts
	rm -rf $(STAGE) $(BUILD)

distclean: clean ## Also drop flashable tars
	rm -f root-build/pmos_uniloader*.tar root-build/pmos_userdata_sparse.tar
