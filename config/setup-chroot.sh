#!/usr/bin/env sh
# config/setup-chroot.sh
#
# Runs inside the target rootfs via `chroot`. Kept separate from the
# interactive `setup-alpine` wizard so the whole install is reproducible.

set -eu

. /build.env
: "${SASS_HOSTNAME:=sendspin}"
: "${SASS_VERSION:=dev}"
: "${SLIM_BUILD:=true}"

echo "====> Install packages"
apk update

# shellcheck disable=SC2046
apk add --no-cache $(grep -vE '^\s*#|^\s*$' /tmp/packages.txt)

pip install --no-cache-dir sendspin --break-system-packages

chmod +x /etc/init.d/sendspin

mkdir -p /etc/doas.d
echo "permit persist :wheel" > /etc/doas.d/doas.conf

echo "${SASS_HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost ${SASS_HOSTNAME}
::1       localhost ${SASS_HOSTNAME}
EOF

echo "====> Setup tzdata"
# tzdata is only needed transiently to seed /etc/localtime, drop it again
apk add --no-cache tzdata
cp "/usr/share/zoneinfo/UTC" /etc/localtime
echo "UTC" > /etc/timezone
apk del tzdata

echo "====> Setup alpine system (non-interactive setup-alpine)"
# setup-alpine normally wires these up interactively; do it explicitly since
# nothing else will enable the services on first boot
rc-update add mdev sysinit
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add hwdrivers sysinit || true
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add syslog boot
rc-update add hwclock boot
rc-update add swap boot
rc-update add networking default
rc-update add sshd default
rc-update add chronyd default
rc-update add sendspin default
rc-update add local default
rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

echo "====> Generate ssh host keys"
rm -f /etc/ssh/ssh_host_*
mkdir -p /etc/local.d
cat > /etc/local.d/00-sshkeys.start <<'EOF'
#!/bin/sh
if [ ! -e /etc/ssh/ssh_host_rsa_key ]; then
    ssh-keygen -A
    rc-service sshd restart >/dev/null 2>&1 || true
fi
EOF
chmod +x /etc/local.d/00-sshkeys.start

echo "====> Generate initial root password"
# must be changed on first login so it isn't left in place long-term
SASS_ROOT_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '=+/' | cut -c1-16)"
echo "root:${SASS_ROOT_PASSWORD}" | chpasswd
passwd -e root >/dev/null 2>&1 || true
{
    echo "SASS ${SASS_VERSION} - initial credentials"
    echo "user: root"
    echo "password: ${SASS_ROOT_PASSWORD}"
    echo "You will be required to set a new password on first login (SSH or console)."
} > /root/CREDENTIALS.txt
chmod 600 /root/CREDENTIALS.txt
# build.sh pulls this out to publish alongside the release artifact
cp /root/CREDENTIALS.txt /CREDENTIALS.txt

echo "====> Setup motd"
cat > /etc/motd <<EOF
SASS - Simple Alpine SendSpin, version ${SASS_VERSION}
See /root/CREDENTIALS.txt for the initial root password.
EOF

echo "====> Cleanup"
# Remove build-deps.txt packages
if [ "${SLIM_BUILD}" = "true" ]; then
    # shellcheck disable=SC2046
    apk del $(grep -vE '^\s*#|^\s*$' /tmp/build-deps.txt) || true
fi

# Don't leave build-only state behind in the shipped image
rm -rf /var/cache/apk/*
rm -f /tmp/packages.txt /tmp/build-deps.txt /build.env
rm -f /build.sh
