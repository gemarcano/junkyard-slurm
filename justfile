# Config

[private]
_apt_packages_file := join("rootfs", "packages.txt")
[private]
_apt_packages := replace(read(_apt_packages_file), "\n", " ")

# Tools

[private]
_repo := require("repo")
[private]
_debootstrap := require("debootstrap")
[private]
_rsync := require("rsync")
[private]
_fallocate := require("fallocate")
[private]
_mkfs_btrfs := require("mkfs.btrfs")
[private]
_mkbootimg := join(justfile_directory(), "tools", "mkbootimg", "mkbootimg.py")
[private]
_bazel := join(justfile_directory(), "kernel", "source", "tools", "bazel")

# Variables

[private]
_kernel_build_dir := join(justfile_directory(), "kernel", "source", "out", "felix", "dist")
[private]
_kernel_version := trim(read(join("kernel", "kernel_version")))
[private]
_sysroot_img := join(justfile_directory(), "boot", "rootfs.img")
[private]
_sysroot_dir := join(justfile_directory(), "rootfs", "sysroot")
[private]
_user := env("USER")
[private]
_module_order_path := join(justfile_directory(), "rootfs", "module_order.txt")
[private]
_initramfs_path := join(_sysroot_dir, "boot", "initrd.img-" + _kernel_version)
[private]
_module_order := replace(read(_module_order_path), "\n", " ")

# Environmental variables, used by Makefile mostly

[private]
export APT_PACKAGES := _apt_packages
[private]
export INITRAMFS_PATH := _initramfs_path
[private]
export KERNEL_BUILD_DIR := _kernel_build_dir
[private]
export KERNEL_SOURCE_DIR := join("kernel", "source")
[private]
export KERNEL_VERSION := _kernel_version
[private]
export MKBOOTIMG := _mkbootimg
[private]
export MODULE_ORDER := _module_order
[private]
export SYSROOT_DIR := _sysroot_dir

# Rules

# Print the list of rules
default:
    just --list

# Clone the Google sources for Felix. This can take around one hour!
[group('kernel')]
[working-directory('kernel/source')]
clone_kernel_source android_kernel_branch="android-gs-felix-6.1-android16":
    @echo "Cloning Android kernel from branch: {{ android_kernel_branch }}"
    {{ _repo }} init \
      --depth=1 \
      -u https://android.googlesource.com/kernel/manifest \
      -b {{ android_kernel_branch }}
    {{ _repo }} sync -j {{ num_cpus() }}

# Clean up the kernel build
[group('kernel')]
[working-directory('kernel/source')]
clean_kernel: clone_kernel_source
    {{ _bazel }} clean --expunge

# Build the kernel
[group('kernel')]
build_kernel: clone_kernel_source
    make -C {{ justfile_directory() }} .build_kernel

# Configure the kernel. This prints a diff that can be used to adjust the custom fragment
[group('kernel')]
[working-directory('kernel/source')]
config_kernel: clone_kernel_source
    cp ./aosp/arch/arm64/configs/gki_defconfig ./gki_defconfig_original
    tools/bazel run //private/devices/google/felix:kernel_config -- nconfig
    diff -up ./gki_defconfig_original aosp/arch/arm64/configs/gki_defconfig; [ $? -eq 0 ] || [ $? -eq 1 ]
    rm ./gki_defconfig_original
    cd aosp; git checkout arch/arm64/configs/gki_defconfig

# Create boot/rootfs.img btrfs image if it doesn't exist
[group('rootfs')]
[working-directory('boot')]
create_rootfs_image size="4GiB": unmount_rootfs
    make -C {{ justfile_directory() }} .create_image SIZE={{ size }}

# Mount the btrfs image
[working-directory('rootfs')]
mount_rootfs size="4GiB": (create_rootfs_image size)
    if ! mountpoint -q {{ _sysroot_dir }}; then \
      sudo mount {{ _sysroot_img }} {{ _sysroot_dir }}; \
    fi

# Unmount the btrfs image
[working-directory('rootfs')]
unmount_rootfs:
    if mountpoint -q {{ _sysroot_dir }}; then \
      sudo umount {{ _sysroot_dir }}; \
    fi

# Delete the rootfs image
[group('rootfs')]
[working-directory('rootfs')]
clean_rootfs: unmount_rootfs
    rm -f {{ _sysroot_img }}

# Populate the rootfs image
[group('rootfs')]
[working-directory('rootfs')]
build_rootfs debootstrap_release="stable" root_password="0000" hostname="fold" size="4GiB": mount_rootfs && unmount_rootfs
    make -C {{ justfile_directory() }} .debootstrap RELEASE={{ debootstrap_release }} ROOT_PW={{ root_password }} HOSTNAME={{ hostname }} SIZE={{ size }}

# Install additional packages into rootfs image
[group('rootfs')]
[working-directory('rootfs')]
install_apt_packages: mount_rootfs && unmount_rootfs
    make -C {{ justfile_directory() }} .install_packages

# Install kernel and headers into rootfs
[group('rootfs')]
[working-directory('rootfs')]
update_kernel_modules_and_source: build_kernel mount_rootfs && unmount_rootfs
    # TODO: Download factory image and copy firmware
    make -C {{ justfile_directory() }} .install_kernel

# TODO: Fix for proper root password (/etc/shadow) maybe with some post service
# Add other user (kalm)
# Add sudo and add user to sudo...
# sudo adduser <username> sudo.
# cat /sys/class/power_supply/battery/capacity
# ADD AOC.bin thing...
# userdata fstab? mkfs if it doesn't have an image...

# Install initramfs into rootfs
[group('rootfs')]
[working-directory('rootfs')]
update_initramfs: mount_rootfs && unmount_rootfs
    make -C {{ justfile_directory() }} .install_initramfs

# Generate the Android flashable images
[group('boot')]
[working-directory('boot')]
build_boot_images: mount_rootfs && unmount_rootfs
    make -C {{ justfile_directory() }} .build_boot

# Clean everything
clean: clean_kernel clean_rootfs
    # FIXME what else should be cleaned?
    make {{ justfile_directory() }} -C clean
