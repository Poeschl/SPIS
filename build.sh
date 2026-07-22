#!/usr/bin/env bash
# build.sh
#
# Builds a flashable SPIS SD card image for Raspberry Pi 3/4, fully
# automated (no interactive raspi-config/Imager customization wizard).
#
# Starts from the official Raspberry Pi OS Lite (arm64) base image and
# customizes it via chroot.
#
# Requires root + losetup, parted, e2fsprogs (resize2fs/e2fsck), zerofree,
# rsync, curl, xz.
#
# Usage: sudo ./build.sh [output-name-without-extension]

set -euo pipefail
#set -x

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. via sudo)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"
DIST_DIR="${SCRIPT_DIR}/dist"
ROOTFS="${WORK_DIR}/root"

RASPIOS_ARCH="${RASPIOS_ARCH:-arm64}"
RASPIOS_IMAGE_URL="${RASPIOS_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_${RASPIOS_ARCH}_latest}"

IMG_SIZE="${IMG_SIZE:-4000M}"
SPIS_HOSTNAME="${SPIS_HOSTNAME:-sendspin}"
SLIM_BUILD="${SLIM_BUILD:-true}"
SPIS_VERSION="${SPIS_VERSION:-$(git -C "${SCRIPT_DIR}" describe --abbrev=7 --dirty --always --tags 2>/dev/null || echo dev)}"

OUTPUT_NAME="${1:-SPIS-${SPIS_VERSION}-${RASPIOS_ARCH}}"
IMG_FILE="${WORK_DIR}/${OUTPUT_NAME}.img"

HOST_ARCH="$(uname -m)"
LOOP_DEV=""
BOOT_MOUNT=""

cleanup() {
    set +e
    if [ -n "${ROOTFS}" ]; then
        umount -fl "${ROOTFS}/proc" 2>/dev/null
        umount -fl "${ROOTFS}/sys" 2>/dev/null
        umount -fl "${ROOTFS}/dev" 2>/dev/null
        umount -fl "${ROOTFS}/tmp" 2>/dev/null
        if [ -n "${BOOT_MOUNT}" ]; then
            umount -fl "${BOOT_MOUNT}" 2>/dev/null
        fi
        umount -fl "${ROOTFS}" 2>/dev/null
    fi
    if [ -n "${LOOP_DEV}" ]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null
    fi
}
trap cleanup EXIT

echo "==> Building SPIS ${SPIS_VERSION} (${RASPIOS_ARCH}) on host ${HOST_ARCH}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${DIST_DIR}" "${ROOTFS}"

echo "==> Download Raspberry Pi OS Lite base image"
curl -fsSL -o "${WORK_DIR}/base.img.xz" "${RASPIOS_IMAGE_URL}"
xz -T0 -d -c "${WORK_DIR}/base.img.xz" > "${IMG_FILE}"
rm -f "${WORK_DIR}/base.img.xz"

echo "==> Grow image to ${IMG_SIZE} and expand the root partition"
truncate -s "${IMG_SIZE}" "${IMG_FILE}"

LOOP_DEV="$(losetup -fP --show "${IMG_FILE}")"
echo "==> Attached ${IMG_FILE} as ${LOOP_DEV}"

# Base image's root partition (p2) only fills its own (much smaller) image;
# grow it to claim the space added above.
parted -s "${LOOP_DEV}" resizepart 2 100%
partprobe "${LOOP_DEV}" 2>/dev/null || true
udevadm settle 2>/dev/null || true

e2fsck -f -y "${LOOP_DEV}p2" || true
resize2fs "${LOOP_DEV}p2"

# Mount root then boot (nested, as on the real device). RaspiOS (Bookworm+)
# mounts the firmware/boot partition at /boot/firmware; older releases use
# /boot directly. Detect which layout the base image uses.
mount "${LOOP_DEV}p2" "${ROOTFS}"
if [ -d "${ROOTFS}/boot/firmware" ]; then
    BOOT_MOUNT="${ROOTFS}/boot/firmware"
else
    BOOT_MOUNT="${ROOTFS}/boot"
fi
mkdir -p "${BOOT_MOUNT}"
mount "${LOOP_DEV}p1" "${BOOT_MOUNT}"

echo "==> Map chroot /tmp for memory backed build space"
mkdir -p "${ROOTFS}/tmp"
# Use tmpfs for /tmp so pip has enough scratch space to build wheels from source
mount -t tmpfs tmpfs "${ROOTFS}/tmp"

echo "==> Mirror card_skeleton/ onto the rootfs"
# No permissions are allowed here, since the boot partition doesn't support this
rsync -a --no-owner --no-group "${SCRIPT_DIR}/card_skeleton/" "${ROOTFS}/"

install -m 644 "${SCRIPT_DIR}/config/packages.txt" "${ROOTFS}/tmp/packages.txt"
install -m 644 "${SCRIPT_DIR}/config/build-deps.txt" "${ROOTFS}/tmp/build-deps.txt"
install -m 755 "${SCRIPT_DIR}/config/setup-chroot.sh" "${ROOTFS}/tmp/setup-chroot.sh"

cat > "${ROOTFS}/build.env" <<EOF
SPIS_HOSTNAME="${SPIS_HOSTNAME}"
SPIS_VERSION="${SPIS_VERSION}"
SLIM_BUILD="${SLIM_BUILD}"
EOF

echo "==> Chroot in and run the non-interactive install"
mount -t proc proc "${ROOTFS}/proc"
mount -t sysfs sysfs "${ROOTFS}/sys"
mount --bind /dev "${ROOTFS}/dev"

# Borrow the host's resolv.conf so DNS/apt work inside the chroot
cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"

chroot "${ROOTFS}" /bin/bash /tmp/setup-chroot.sh

rm -f "${ROOTFS}/etc/resolv.conf"

umount -fl "${ROOTFS}/proc"
umount -fl "${ROOTFS}/sys"
umount -fl "${ROOTFS}/dev"
umount -fl "${ROOTFS}/tmp"

echo "==> Retrieve credentials and cleanup"
if [ -f "${ROOTFS}/CREDENTIALS.txt" ]; then
    cp "${ROOTFS}/CREDENTIALS.txt" "${DIST_DIR}/${OUTPUT_NAME}-CREDENTIALS.txt"
    chmod 644 "${DIST_DIR}/${OUTPUT_NAME}-CREDENTIALS.txt"
    rm -f "${ROOTFS}/CREDENTIALS.txt"
fi

# Do this at last, additively, so nothing installed during the chroot step
# (e.g. raspi-firmware package hooks) clobbers our tweaks.
echo "==> Append audio/boot tuning to config.txt"
cat "${SCRIPT_DIR}/config/config-append.txt" >> "${BOOT_MOUNT}/config.txt"

echo "SPIS version: ${SPIS_VERSION}" > "${ROOTFS}/version-info"
cp "${ROOTFS}/version-info" "${DIST_DIR}/version-info"

echo "==> Shrink the image"
# zero-fill boot free space, trim+zero root
dd if=/dev/zero of="${BOOT_MOUNT}/.zero" bs=1M 2>/dev/null || true
rm -f "${BOOT_MOUNT}/.zero"
fstrim -v "${ROOTFS}" || true

umount "${BOOT_MOUNT}"
umount "${ROOTFS}"

e2fsck -f -y "${LOOP_DEV}p2" || true
if command -v zerofree >/dev/null 2>&1; then
    zerofree -v "${LOOP_DEV}p2"
fi

losetup -d "${LOOP_DEV}"
LOOP_DEV=""

echo "==> Compress the image"
xz -T0 -f "${IMG_FILE}"
mv "${IMG_FILE}.xz" "${DIST_DIR}/${OUTPUT_NAME}.img.xz"

echo "==> Done: ${DIST_DIR}/${OUTPUT_NAME}.img.xz"
echo "==> Initial root credentials: ${DIST_DIR}/${OUTPUT_NAME}-CREDENTIALS.txt"

rm -rf "${WORK_DIR}"
