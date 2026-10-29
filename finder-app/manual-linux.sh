#!/bin/bash
# Script outline to install and build kernel.
# Author: Siddhant Jajoo.

set -e
set -u

OUTDIR=/tmp/aeld
KERNEL_REPO=git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git
KERNEL_VERSION=v5.15.163
BUSYBOX_VERSION=1_33_1
FINDER_APP_DIR=$(realpath $(dirname $0))
ARCH=arm64
CROSS_COMPILE=aarch64-none-linux-gnu-

if [ $# -lt 1 ]
then
	echo "Using default directory ${OUTDIR} for output"
else
	OUTDIR=$1
	echo "Using passed directory ${OUTDIR} for output"
fi

if ! mkdir -p "${OUTDIR}"; then
    echo "ERROR: Failed to create output directory: ${OUTDIR}" >&2
    exit 1
fi
OUTDIR=$(realpath "${OUTDIR}")

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/linux-stable" ]; then
    echo "Cloning Linux stable version ${KERNEL_VERSION}"
    git clone "${KERNEL_REPO}" \
        --depth 1 \
        --single-branch \
        --branch "${KERNEL_VERSION}"
fi

cd "${OUTDIR}/linux-stable"

echo "Checking out kernel version ${KERNEL_VERSION}"
git checkout "${KERNEL_VERSION}"

echo "Configuring Linux kernel"
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" defconfig

echo "Building Linux kernel Image"
make -j"$(nproc)" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" Image

echo "Adding the Image in outdir"
cp "${OUTDIR}/linux-stable/arch/${ARCH}/boot/Image" "${OUTDIR}/Image"

echo "Creating the staging directory for the root filesystem"
cd "$OUTDIR"
if [ -d "${OUTDIR}/rootfs" ]
then
	echo "Deleting rootfs directory at ${OUTDIR}/rootfs and starting over"
    sudo rm  -rf ${OUTDIR}/rootfs
fi

mkdir -p "${OUTDIR}/rootfs"
mkdir -p "${OUTDIR}/rootfs"/{bin,sbin,etc,proc,sys,dev,tmp,usr/bin,usr/sbin,home,lib,lib64}

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/busybox" ]; then
    echo "Cloning BusyBox"
    git clone https://git.busybox.net/busybox "${OUTDIR}/busybox"
fi

cd "${OUTDIR}/busybox"

echo "Checking out BusyBox version ${BUSYBOX_VERSION}"
git checkout "${BUSYBOX_VERSION}"

echo "Configuring BusyBox"
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} defconfig

echo "Building BusyBox"
make -j"$(nproc)" ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}

echo "Installing BusyBox into rootfs"
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} CONFIG_PREFIX="${OUTDIR}/rootfs" install

echo "BusyBox program interpreter"
${CROSS_COMPILE}readelf -l "${OUTDIR}/busybox/busybox" | grep -F "interpreter" || true

echo "BusyBox shared-library dependencies"
${CROSS_COMPILE}readelf -d "${OUTDIR}/busybox/busybox" | grep -F "NEEDED" || true

echo "Copying ARM64 runtime libraries"

# Locate the ARM64 runtime libraries from the cross-compiler
LIBC_PATH=$(${CROSS_COMPILE}gcc -print-file-name=libc.so.6)
LIBM_PATH=$(${CROSS_COMPILE}gcc -print-file-name=libm.so.6)
LIBRESOLV_PATH=$(${CROSS_COMPILE}gcc -print-file-name=libresolv.so.2)
LOADER_PATH=$(${CROSS_COMPILE}gcc -print-file-name=ld-linux-aarch64.so.1)

# Ensure all required runtime libraries exist
for LIB_PATH in "${LIBC_PATH}" "${LIBM_PATH}" "${LIBRESOLV_PATH}" "${LOADER_PATH}"; do
    if [ ! -f "${LIB_PATH}" ]; then
        echo "ERROR: Runtime library not found: ${LIB_PATH}" >&2
        exit 1
    fi
done

# Copy runtime libraries into the target root filesystem
mkdir -p "${OUTDIR}/rootfs/lib"

cp -L "${LIBC_PATH}" "${OUTDIR}/rootfs/lib/libc.so.6"
cp -L "${LIBM_PATH}" "${OUTDIR}/rootfs/lib/libm.so.6"
cp -L "${LIBRESOLV_PATH}" "${OUTDIR}/rootfs/lib/libresolv.so.2"
cp -L "${LOADER_PATH}" "${OUTDIR}/rootfs/lib/ld-linux-aarch64.so.1"

# Also provide runtime libraries under /lib64
mkdir -p "${OUTDIR}/rootfs/lib64"

cp -L "${LIBC_PATH}" "${OUTDIR}/rootfs/lib64/libc.so.6"
cp -L "${LIBM_PATH}" "${OUTDIR}/rootfs/lib64/libm.so.6"
cp -L "${LIBRESOLV_PATH}" "${OUTDIR}/rootfs/lib64/libresolv.so.2"
cp -L "${LOADER_PATH}" "${OUTDIR}/rootfs/lib64/ld-linux-aarch64.so.1"

echo "Runtime libraries copied successfully"

if [ ! -e "${OUTDIR}/rootfs/dev/console" ]; then
    sudo mknod -m 600 "${OUTDIR}/rootfs/dev/console" c 5 1
fi

if [ ! -e "${OUTDIR}/rootfs/dev/null" ]; then
    sudo mknod -m 666 "${OUTDIR}/rootfs/dev/null" c 1 3
fi


echo "Cleaning writer application"
make -C "${FINDER_APP_DIR}" clean

echo "Building writer application for ARM64"
make -C "${FINDER_APP_DIR}" CROSS_COMPILE="${CROSS_COMPILE}"

# Copy the cross-compiled writer into the target root filesystem
cp "${FINDER_APP_DIR}/writer" "${OUTDIR}/rootfs/home/writer"


# Copy finder scripts and configuration files into rootfs/home
echo "Copying finder application files"

mkdir -p "${OUTDIR}/rootfs/home/conf"

cp "${FINDER_APP_DIR}/finder.sh" "${OUTDIR}/rootfs/home/"
cp "${FINDER_APP_DIR}/finder-test.sh" "${OUTDIR}/rootfs/home/"
cp "${FINDER_APP_DIR}/autorun-qemu.sh" "${OUTDIR}/rootfs/home/"

cp "${FINDER_APP_DIR}/conf/username.txt" "${OUTDIR}/rootfs/home/conf/"
cp "${FINDER_APP_DIR}/conf/assignment.txt" "${OUTDIR}/rootfs/home/conf/"

# Ensure scripts are executable
chmod +x "${OUTDIR}/rootfs/home/finder.sh"
chmod +x "${OUTDIR}/rootfs/home/finder-test.sh"
chmod +x "${OUTDIR}/rootfs/home/autorun-qemu.sh"

# Set ownership of the root filesystem
echo "Setting root filesystem ownership"
sudo chown -R root:root "${OUTDIR}/rootfs"

# Create the compressed initramfs archive
echo "Creating initramfs.cpio.gz"

(
    cd "${OUTDIR}/rootfs"
    sudo find . -print0 |
        sudo cpio --null -ov --format=newc --owner=0:0 |
        gzip -9 > "${OUTDIR}/initramfs.cpio.gz"
)

echo "Kernel image: ${OUTDIR}/Image"
echo "Initramfs: ${OUTDIR}/initramfs.cpio.gz"
echo "Build preparation complete"
