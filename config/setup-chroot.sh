#!/usr/bin/env bash
# config/setup-chroot.sh
#
# Runs inside the target rootfs via `chroot`. Kept separate so the whole
# install is reproducible without any interactive raspi-config/Imager step.

set -euo pipefail

. /build.env
: "${SPIS_HOSTNAME:=sendspin}"
: "${SPIS_VERSION:=dev}"
: "${SLIM_BUILD:=true}"

export DEBIAN_FRONTEND=noninteractive

echo "====> Install packages"
apt-get update
# shellcheck disable=SC2046
apt-get install -y --no-install-recommends $(grep -vE '^\s*#|^\s*$' /tmp/packages.txt)

echo "====> Install sendspin"
pip install --no-cache-dir --break-system-packages sendspin

echo "====> Enable sendspin service"
systemctl enable sendspin.service

echo "====> Config hostname"
echo "${SPIS_HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost ${SPIS_HOSTNAME}
::1       localhost ${SPIS_HOSTNAME}
EOF

echo "====> Setup tzdata"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

echo "====> Enable ssh and allow root login"
systemctl enable ssh
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-spis-root-login.conf <<EOF
PermitRootLogin yes
EOF

echo "====> Regenerate ssh host keys on first boot"
# Remove the keys baked into the base image; raspberrypi-sys-mods'
# regenerate_ssh_host_keys.service (if present) or a manual ssh-keygen -A on
# first boot recreates them so every card gets unique host keys.
rm -f /etc/ssh/ssh_host_*
systemctl enable regenerate_ssh_host_keys.service >/dev/null 2>&1 || true

echo "====> Generate initial root password"
# must be changed on first login so it isn't left in place long-term
SPIS_ROOT_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '=+/' | cut -c1-16)"
echo "root:${SPIS_ROOT_PASSWORD}" | chpasswd
passwd -u root >/dev/null 2>&1 || true
chage -d 0 root >/dev/null 2>&1 || true
{
    echo "SPIS ${SPIS_VERSION} - initial credentials"
    echo "user: root"
    echo "password: ${SPIS_ROOT_PASSWORD}"
    echo "You will be required to set a new password on first login (SSH or console)."
} > /root/CREDENTIALS.txt
chmod 600 /root/CREDENTIALS.txt
# build.sh pulls this out to publish alongside the release artifact
cp /root/CREDENTIALS.txt /CREDENTIALS.txt

echo "====> Cleanup"
# Remove build-deps.txt packages
if [ "${SLIM_BUILD}" = "true" ]; then
    # shellcheck disable=SC2046
    apt-get purge -y $(grep -vE '^\s*#|^\s*$' /tmp/build-deps.txt) || true
    apt-get autoremove -y || true
fi

# Don't leave build-only state behind in the shipped image
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /tmp/packages.txt /tmp/build-deps.txt /build.env
rm -f /build.sh
