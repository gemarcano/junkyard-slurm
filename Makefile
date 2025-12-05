.PHONY: all clean

# This file is meant to be called by the justfile, not manually

RELEASE ?= stable
ROOT_PW ?= 0000
HOSTNAME ?= fold
SIZE ?= 4GiB
SYSROOT_DIR ?= rootfs/sysroot
KERNEL_SOURCE_DIR ?= kernel/source
KERNEL_BUILD_DIR ?= $(KERNEL_SOURCE_DIR)/out/felix/dist
APT_PACKAGES_FILE ?= rootfs/packages.txt
MODULE_ORDER_PATH ?= rootfs/module_order.txt
ROOTFS_IMG ?= boot/rootfs.img
MKBOOTIMG ?= tools/mkbootimg/mkbootimg.py
BAZEL ?= kernel/source/tools/bazel

all:
	@echo "This should not be run manually! Use just instead!"
	@just

.create_image:
	mkdir -p $(SYSROOT_DIR)
	sudo fallocate -l $(SIZE) $(ROOTFS_IMG)
	sudo mkfs.btrfs $(ROOTFS_IMG)
	touch $@

.debootstrap: .create_image rootfs/usb_gadget.sh rootfs/00-boot-modules.conf
	just mount_rootfs
	# First stage
	sudo debootstrap --variant=minbase --include=symlinks --arch=arm64 --foreign $(RELEASE) $(SYSROOT_DIR)
	# Second stage
	sudo systemd-nspawn -D $(SYSROOT_DIR) debootstrap/debootstrap --second-stage
	sudo systemd-nspawn -D $(SYSROOT_DIR) symlinks -cr .
	# Set password
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c "echo root:$(ROOT_PW) | chpasswd"
	# Set hostname
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c "echo $(HOSTNAME) > /etc/hostname"
	# Copy extra files
	sudo cp rootfs/usb_gadget.sh $(SYSROOT_DIR)/usr/local/bin/
	sudo mkdir -p $(SYSROOT_DIR)/etc/modules-load.d/
	sudo cp rootfs/00-boot-modules.conf $(SYSROOT_DIR)/etc/modules-load.d/
	just unmount_rootfs
	# and make sentinel
	touch $@

.build_kernel: kernel/source/custom_defconfig_mod/BUILD.bazel kernel/source/custom_defconfig_mod/custom_defconfig
	cd $(KERNEL_SOURCE_DIR); $(BAZEL) run \
		--config=use_source_tree_aosp \
		--config=stamp \
		--config=felix \
		--defconfig_fragment=//custom_defconfig_mod:custom_defconfig \
		//private/devices/google/felix:gs201_felix_dist
	@echo "Updating kernel version string"
	strings $(KERNEL_BUILD_DIR)/Image | grep "Linux version" | head -n 1 | awk '{print $$3}' > $(KERNEL_SOURCE_DIR)/kernel_version
	touch $@

.install_packages: .debootstrap rootfs/packages.txt
	just mount_rootfs
	# Setup locale
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -y install locales apt-utils"
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c \
		"export DEBIAN_FRONTEND=noninteractive; \
		sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
		&& dpkg-reconfigure locales \
		&& update-locale en_US.UTF-8"
	# Actually install packages
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -y install $(APT_PACKAGES)"
	sudo systemd-nspawn -D ${SYSROOT_DIR} systemctl disable dhcpcd
	sudo systemd-nspawn -D ${SYSROOT_DIR} systemctl enable NetworkManager
	just unmount_rootfs
	touch $@

.install_kernel: .build_kernel .create_image
	just mount_rootfs
	sudo mkdir -p $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)
	sudo cp $(KERNEL_BUILD_DIR)/modules.builtin $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/
	sudo cp $(KERNEL_BUILD_DIR)/modules.builtin.modinfo $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/
	sudo rm -f $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/modules.order
	sudo touch $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/modules.order
	@echo "Copying modules"
	for staging in vendor_dlkm system_dlkm; \
	do \
		mkdir -p rootfs/unpack/"$$staging" && \
		tar \
		-xvzf $(KERNEL_BUILD_DIR)/"$$staging"_staging_archive.tar.gz \
		-C rootfs/unpack/"$$staging"; \
		sudo rsync -avK --ignore-existing --include='*/' --include='*.ko' --exclude='*' rootfs/unpack/"$$staging"/ $(SYSROOT_DIR)/; \
		sudo sh -c "cat rootfs/unpack/\"$$staging\"/lib/modules/$(KERNEL_VERSION)/modules.order \
		>> $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/modules.order"; \
	done
	@echo "Updating System.map"
	sudo cp $(KERNEL_BUILD_DIR)/System.map $(SYSROOT_DIR)/boot/System.map-$(KERNEL_VERSION)
	@echo "Updating module dependencies"
	sudo systemd-nspawn -D $(SYSROOT_DIR) depmod \
		--errsyms \
		--all \
		--filesyms /boot/System.map-$(KERNEL_VERSION) \
		$(KERNEL_VERSION)
	@echo "Copying kernel headers"
	mkdir -p rootfs/unpack/kernel_headers
	tar \
		-xvzf $(KERNEL_BUILD_DIR)/kernel-headers.tar.gz \
		-C rootfs/unpack/kernel_headers
	sudo cp -r rootfs/unpack/kernel_headers $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION)
	sudo ln -rsf $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION) $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/build
	sudo cp $(KERNEL_BUILD_DIR)/kernel_aarch64_Module.symvers $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION)/
	sudo cp $(KERNEL_BUILD_DIR)/vmlinux.symvers $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION)/
	#
	@echo "Setting systemd module load order"
	rm -f $(MODULE_ORDER_PATH)
	#
	cat $(KERNEL_BUILD_DIR)/vendor_kernel_boot.modules.load | xargs -I {} \
		modinfo -b $(SYSROOT_DIR) -k $(KERNEL_VERSION) -F name "$(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/{}" \
		> $(MODULE_ORDER_PATH)
	cat $(KERNEL_BUILD_DIR)/vendor_dlkm.modules.load | xargs -I {} \
		modinfo -b $(SYSROOT_DIR) -k $(KERNEL_VERSION) -F name "$(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/{}" \
		>> $(MODULE_ORDER_PATH)
	cat $(KERNEL_BUILD_DIR)/system_dlkm.modules.load | xargs -I {} \
		modinfo -b $(SYSROOT_DIR) -k $(KERNEL_VERSION) -F name "$(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/{}" \
		>> $(MODULE_ORDER_PATH)
	csplit $(MODULE_ORDER_PATH) -f "module_order" -b ".%02d.txt" "/ufs_pixel_fips140/+1"
	mv module_order.00.txt $(MODULE_ORDER_PATH)
	mv module_order.01.txt 00-boot-modules.conf
	just unmount_rootfs
	touch $@

.install_initramfs: .install_kernel rootfs/module_order.txt .install_packages
	just mount_rootfs
	sudo mkdir -p "$(SYSROOT_DIR)/etc/dracut.conf.d/"
	sudo sh -c "echo \"force_drivers+=\\\" $(MODULE_ORDER) \\\"\" > \"$(SYSROOT_DIR)/etc/dracut.conf.d/module_order.conf\""
	sudo systemd-nspawn -D $(SYSROOT_DIR) dracut \
		--kver $(KERNEL_VERSION) \
		--lz4 \
		--show-modules \
		--force \
		--add "rescue bash" \
		--kernel-cmdline "rd.shell"
	just unmount_rootfs
	touch $@

.build_boot: .install_initramfs
	sudo $(MKBOOTIMG) \
		--kernel $(KERNEL_BUILD_DIR)/Image.lz4 \
		--cmdline "root=/dev/disk/by-partlabel/super" \
		--header_version 4 \
		-o boot/boot.img \
		--pagesize 2048 \
		--os_version 15.0.0 \
		--os_patch_level 2025-02
	just mount_rootfs
	sudo $(MKBOOTIMG) \
		--ramdisk_name "" \
		--vendor_ramdisk_fragment $(INITRAMFS_PATH) \
		--dtb $(KERNEL_BUILD_DIR)/dtb.img \
		--header_version 4 \
		--vendor_boot boot/vendor_boot.img \
		--pagesize 2048 \
		--os_version 15.0.0 \
		--os_patch_level 2025-02
	just unmount_rootfs
	touch $@

clean:
	just unmount_rootfs
	rm -rf boot/rootfs.img .build_boot .install_initramfs .install_kernel .install_packages .build_kernel .create_image .debootstrap
	rm -rf boot/boot.img boot/vendor_boot.img boot/rootfs.img
