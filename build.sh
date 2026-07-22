#!/usr/bin/env bash
# build.sh
#
# Builds a flashable SASS SD card image for Raspberry Pi 3/4, fully
# automated (no interactive setup-alpine wizard).
#
# Requires root + sfdisk/losetup, mkfs.vfat, mkfs.ext4/e2fsck, zerofree,
# rsync, curl, tar, xz.
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

ALPINE_BRANCH="${ALPINE_BRANCH:-3.24}"
ALPINE_ARCH="${ALPINE_ARCH:-armv7}"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}"

IMG_SIZE="${IMG_SIZE:-1200M}"
SASS_HOSTNAME="${SASS_HOSTNAME:-sendspin}"
SLIM_BUILD="${SLIM_BUILD:-true}"
SASS_VERSION="${SASS_VERSION:-$(git -C "${SCRIPT_DIR}" describe --abbrev=7 --dirty --always --tags 2>/dev/null || echo dev)}"
DISK_ID="${DISK_ID:-0x00000666}" # must match PARTUUID=00000666-0N in card_skeleton

OUTPUT_NAME="${1:-sass-${SASS_VERSION}-${ALPINE_ARCH}}"
IMG_FILE="${WORK_DIR}/${OUTPUT_NAME}.img"

HOST_ARCH="$(uname -m)"
LOOP_DEV=""

cleanup() {
    set +e
    if [ -n "${ROOTFS}" ]; then
        umount -fl "${ROOTFS}/proc" 2>/dev/null
        umount -fl "${ROOTFS}/sys" 2>/dev/null
        umount -fl "${ROOTFS}/dev" 2>/dev/null
        umount -fl "${ROOTFS}/tmp" 2>/dev/null
        umount -fl "${ROOTFS}/boot" 2>/dev/null
        umount -fl "${ROOTFS}" 2>/dev/null
    fi
    if [ -n "${LOOP_DEV}" ]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null
    fi
}
trap cleanup EXIT

echo "==> Building SASS ${SASS_VERSION} (${ALPINE_ARCH}) on host ${HOST_ARCH}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${DIST_DIR}" "${ROOTFS}"

# Fetch a static apk binary for the host arch to bootstrap the target rootfs
APK_STATIC="${WORK_DIR}/apk.static"
APK_PKG_NAME="$(curl -fsSL "${MIRROR}/main/${HOST_ARCH}/" \
    | grep -oE 'apk-tools-static-[0-9][^"]*\.apk' | sort -V | tail -n1)"
if [ -z "${APK_PKG_NAME}" ]; then
    echo "Could not determine apk-tools-static package name for ${HOST_ARCH}" >&2
    exit 1
fi
curl -fsSL -o "${WORK_DIR}/apk-tools-static.apk" "${MIRROR}/main/${HOST_ARCH}/${APK_PKG_NAME}"
# .apk files are gzip tarballs; extract the static apk binary
tar -xz -f "${WORK_DIR}/apk-tools-static.apk" -C "${WORK_DIR}" sbin/apk.static
mv "${WORK_DIR}/sbin/apk.static" "${APK_STATIC}"
chmod +x "${APK_STATIC}"

echo "==> Create partitions"
# Create + partition the disk image (p1 = FAT32 boot, p2 = ext4 root)
truncate -s "${IMG_SIZE}" "${IMG_FILE}"

sfdisk "${IMG_FILE}" <<EOF
label: dos
label-id: ${DISK_ID}
unit: sectors

start=2048, size=524288, type=c, bootable
start=526336, type=83
EOF

LOOP_DEV="$(losetup -fP --show "${IMG_FILE}")"
echo "==> Attached ${IMG_FILE} as ${LOOP_DEV}"

mkfs.vfat -F32 -n BOOT "${LOOP_DEV}p1"
mkfs.ext4 -F -L root "${LOOP_DEV}p2"

# Mount root then boot (nested, as on the real device)
mount "${LOOP_DEV}p2" "${ROOTFS}"
mkdir -p "${ROOTFS}/boot"
mount "${LOOP_DEV}p1" "${ROOTFS}/boot"

echo "==> Bootstrap minimal alpine root fs"
"${APK_STATIC}" \
    -X "${MIRROR}/main" -X "${MIRROR}/community" \
    --arch "${ALPINE_ARCH}" -U --allow-untrusted \
    --root "${ROOTFS}" --initdb add alpine-base

echo "==> Map chroot /tmp for memory backed build space"
mkdir -p "${ROOTFS}/tmp"
# Use tmpfs for /tmp so pip has enough scratch space to build wheels from source
mount -t tmpfs tmpfs "${ROOTFS}/tmp"

echo "==> Mirror card_skeleton/ onto the rootfs"
# No permissions are allowed here, since the boot partition doesn't support this
rsync -a --no-owner --no-group "${SCRIPT_DIR}/card_skeleton/" "${ROOTFS}/"

sed -i "s/__ALPINE_BRANCH__/${ALPINE_BRANCH}/g" "${ROOTFS}/etc/apk/repositories"
chmod +x "${ROOTFS}/etc/init.d/sendspin"

install -m 644 "${SCRIPT_DIR}/config/packages.txt" "${ROOTFS}/tmp/packages.txt"
install -m 644 "${SCRIPT_DIR}/config/build-deps.txt" "${ROOTFS}/tmp/build-deps.txt"
install -m 755 "${SCRIPT_DIR}/config/setup-chroot.sh" "${ROOTFS}/tmp/setup-chroot.sh"

cat > "${ROOTFS}/build.env" <<EOF
SASS_HOSTNAME="${SASS_HOSTNAME}"
SASS_VERSION="${SASS_VERSION}"
SLIM_BUILD="${SLIM_BUILD}"
EOF

# Fallback QEMU binary in case the kernel lacks AArch32 compat support
if [ "${HOST_ARCH}" != "armv7" ] && [ "${HOST_ARCH}" != "armv7l" ] && command -v qemu-arm-static >/dev/null 2>&1; then
    echo "### !!! Using qemu arm emulation"
    mkdir -p "${ROOTFS}/usr/bin"
    cp "$(command -v qemu-arm-static)" "${ROOTFS}/usr/bin/qemu-arm-static"
fi

echo "==> Chroot in and run the non-interactive install"
mount -t proc proc "${ROOTFS}/proc"
mount -t sysfs sysfs "${ROOTFS}/sys"
mount --bind /dev "${ROOTFS}/dev"

# Borrow the host's resolv.conf so DNS/apk work inside the chroot
cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"

chroot "${ROOTFS}" /bin/sh /tmp/setup-chroot.sh

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

rm -f "${ROOTFS}/usr/bin/qemu-arm-static"

# Do this at last to ensure boot of the pi
echo "==> Re-apply config.txt / cmdline.txt"
install -m 644 "${SCRIPT_DIR}/card_skeleton/boot/config.txt" "${ROOTFS}/boot/config.txt"
install -m 644 "${SCRIPT_DIR}/card_skeleton/boot/cmdline.txt" "${ROOTFS}/boot/cmdline.txt"

echo "SASS version: ${SASS_VERSION}" > "${ROOTFS}/version-info"
cp "${ROOTFS}/version-info" "${DIST_DIR}/version-info"

echo "==> Shrink the image"
# zero-fill boot free space, trim+zero root
dd if=/dev/zero of="${ROOTFS}/boot/.zero" bs=1M 2>/dev/null || true
rm -f "${ROOTFS}/boot/.zero"
fstrim -v "${ROOTFS}" || true

umount "${ROOTFS}/boot"
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
