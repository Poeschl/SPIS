# SPIS - Manual Installation Guide

This guide walks you through building SPIS (Simple PI SendSpin) on Raspberry Pi OS Lite by
hand, replicating exactly what `build.sh` / `config/setup-chroot.sh` automate in CI
(`.github/workflows/build-image.yml`). This is useful for:
- Understanding how the automated image is built
- Troubleshooting issues on real hardware
- Creating variations for different hardware
- Installing SPIS onto an already-running Raspberry Pi instead of flashing a prebuilt image

## Prerequisites

- Raspberry Pi 3 or 4
- MicroSD card (8GB minimum, 16GB recommended)
- USB Audio DAC (optional, onboard headphone jack works out of the box)
- Network connection (Ethernet recommended)
- Another computer to prepare the SD card

## Step 1: Download Raspberry Pi OS Lite

1. Visit https://www.raspberrypi.com/software/operating-systems/
2. Download **Raspberry Pi OS Lite (64-bit)** (`raspios_lite_arm64`)
3. Or use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash it directly to the SD card

## Step 2: Flash the Image

**Using Raspberry Pi Imager (recommended, all platforms):**
1. Select "Raspberry Pi OS Lite (64-bit)" as the OS
2. Select your SD card
3. In the settings (gear icon), enable SSH and set a username/password if you want first-boot access already configured
4. Write the image

**Using dd (Linux/macOS), after extracting the downloaded `.img.xz`:**
```bash
dd if=raspios-lite.img of=/dev/sdX bs=4M status=progress
sync
```

## Step 3: First Boot and Basic Setup

1. Insert SD card into Raspberry Pi
2. Connect Ethernet cable
3. Power on and wait ~30 seconds
4. Find the Pi's IP address (check your router or use `nmap`)
5. SSH into the Pi with the user configured in Imager (or `pi`, if you used that flow)

```bash
ssh <user>@<pi-ip-address>
```

## Step 4: Update the System

```bash
sudo apt-get update
sudo apt-get upgrade -y
```

## Step 5: Install System Dependencies

This is the exact package list from `config/packages.txt` (runtime packages, build
dependencies, and `doas`):

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    openssh-server chrony \
    alsa-utils libasound2 \
    python3 python3-pip python3-venv \
    gcc python3-dev build-essential libopenblas-dev gfortran \
    libavformat-dev libavcodec-dev libavdevice-dev libavutil-dev libswscale-dev \
    libswresample-dev pkg-config libffi-dev libjpeg-dev zlib1g-dev \
    portaudio19-dev libportaudio2 \
    doas
```

## Step 6: Install SendSpin

```bash
sudo pip install --no-cache-dir --break-system-packages sendspin
```

This will take 10-20 minutes on a Raspberry Pi 3 as it compiles numpy and other packages.

**Note:** The `--break-system-packages` flag is needed because Debian/RaspiOS marks the
system Python as externally managed (PEP 668). This is safe for a dedicated appliance.

## Step 7: Add SendSpin to PATH

If installing as root (as above), sendspin is installed to `/usr/local/bin` and is
already on `PATH`. If installing as a non-root user instead:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
source ~/.profile
```

## Step 8: Enable SSH and Allow Root Login

The image ships with SSH enabled and root login permitted, so it's reachable
immediately after first boot without going through `raspi-config`:

```bash
sudo systemctl enable ssh
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/10-spis-root-login.conf > /dev/null <<'EOF'
PermitRootLogin yes
EOF
```

If you're preparing an image for distribution (not just your own device), also
regenerate the SSH host keys so every card gets unique ones on first boot:

```bash
sudo rm -f /etc/ssh/ssh_host_*
sudo systemctl enable regenerate_ssh_host_keys.service
```

## Step 9: Set Hostname and Timezone

```bash
echo "sendspin" | sudo tee /etc/hostname
sudo tee /etc/hosts > /dev/null <<'EOF'
127.0.0.1 localhost sendspin
::1       localhost sendspin
EOF

sudo ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" | sudo tee /etc/timezone
sudo dpkg-reconfigure -f noninteractive tzdata
```

Replace `sendspin` with your preferred hostname, and `UTC` with your preferred timezone.

## Step 10: Configure USB Audio

### Check USB DAC is detected

```bash
aplay -l
```

You should see your USB device listed as card 0 or card 1.

### Create ALSA Configuration

```bash
sudo nano /etc/asound.conf
```

Add this content (adjust card number/name if needed):

```
pcm.!default {
    type plug
    slave.pcm "hw:0,0"
}

ctl.!default {
    type hw
    card 0
}
```

**Important:** Change `0` to match your USB DAC number/name from `aplay -l`. By default
(no `/etc/asound.conf`) the onboard 3.5mm jack (card `Headphones`) is used.

### Test Audio

```bash
speaker-test -c 2 -r 48000 -D hw:0,0
```

You should hear pink noise. Press Ctrl+C to stop.

### Boot Config Tuning

Append this to `/boot/firmware/config.txt` (Bookworm+) or `/boot/config.txt` (older
releases):

```bash
sudo tee -a /boot/firmware/config.txt > /dev/null <<'EOF'

# --- SPIS - Simple PI SendSpin --- #
# Enable audio (onboard + required for USB audio class detection)
dtparam=audio=on

# Give the GPU minimal memory, headless audio appliance
gpu_mem=16

# Boot faster
disable_splash=1
boot_delay=0
EOF
```

## Step 11: Install the Volume-Fixing Helper Script

Every mixer control on every detected card is forced to 100%/unmuted before
sendspin starts, so playback is never quietened by a leftover or driver-default
mixer level:

```bash
sudo tee /usr/local/sbin/set-audio-volume.sh > /dev/null <<'EOF'
#!/bin/sh
for card_path in /proc/asound/card[0-9]*; do
    [ -e "$card_path" ] || continue
    card_num=${card_path##*card}

    amixer -c "$card_num" scontrols 2>/dev/null | awk -F "'" '{print $2}' | while IFS= read -r ctrl; do
        [ -n "$ctrl" ] || continue
        amixer -c "$card_num" sset "$ctrl" 100% unmute >/dev/null 2>&1 || true
    done
done

exit 0
EOF
sudo chmod 755 /usr/local/sbin/set-audio-volume.sh
```

## Step 12: Create SendSpin Service

Create the systemd unit:

```bash
sudo tee /etc/systemd/system/sendspin.service > /dev/null <<'EOF'
[Unit]
Description=SendSpin Audio Player
Documentation=https://github.com/Sendspin/sendspin-cli
After=network-online.target sound.target systemd-udev-settle.service
Wants=network-online.target systemd-udev-settle.service

[Service]
Type=simple
User=root
# Wait for at least one ALSA card to show up before starting.
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do [ -s /proc/asound/cards ] && exit 0; sleep 1; done; echo "No ALSA card detected after 30s, starting anyway" >&2; exit 0'
# Fix every ALSA mixer control (Master/PCM/Headphone/etc, on every detected card) to 100% and unmuted
ExecStartPre=/usr/local/sbin/set-audio-volume.sh
ExecStart=/usr/local/bin/sendspin --headless
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

**Note:** If you installed as a non-root user, change `User=` and the `ExecStart` path
to `/home/username/.local/bin/sendspin`.

Enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now sendspin
```

Check status:

```bash
systemctl status sendspin
```

## Step 13: Optional - Set the Default SendSpin Settings

The image ships a default player name/settings file so devices identify themselves
consistently on the network:

```bash
sudo mkdir -p /root/.config/sendspin
sudo tee /root/.config/sendspin/settings-daemon.json > /dev/null <<'EOF'
{
  "player_volume": 100,
  "player_muted": false,
  "use_mpris": true,
  "product_name": "Simple PI SendSpin"
}
EOF
```

## Step 14: Optional - Configure doas as a sudo alternative

For easier administration:

```bash
sudo apt-get install -y doas

# Configure doas
echo "permit persist :sudo" | sudo tee /etc/doas.conf

# Add a user (if desired)
sudo adduser yourname
sudo usermod -aG sudo yourname
```

## Step 15: Set a Root Password

The automated build generates a random root password (forced to be changed on
first login) and writes it to a `CREDENTIALS.txt` file. When installing by hand,
just set your own:

```bash
sudo passwd root
```

## Step 16: Test SendSpin

SendSpin should now be running and visible to Music Assistant on your network.

Check logs:
```bash
journalctl -u sendspin -e
```

Manual test (stop service first):
```bash
sudo systemctl stop sendspin
sendspin --headless
# Press Ctrl+C to stop
sudo systemctl start sendspin
```

## Step 17: Cleanup (Optional)

If you want to reduce image size, you can remove the build dependencies listed in
`config/build-deps.txt` after sendspin is installed:

```bash
sudo apt-get purge -y gcc python3-dev build-essential libopenblas-dev gfortran \
    libavformat-dev libavcodec-dev libavdevice-dev libavutil-dev libswscale-dev \
    libswresample-dev pkg-config libffi-dev libjpeg-dev zlib1g-dev portaudio19-dev
sudo apt-get autoremove -y
sudo apt-get clean
```

**Warning:** Don't do this if you plan to install more Python packages later!

## Troubleshooting

### SendSpin command not found

- Check PATH: `echo $PATH`
- Find sendspin: `find / -name sendspin 2>/dev/null`
- Add to PATH or use full path

### Audio pops/crackles

Try increasing buffer size in `/etc/asound.conf`:

```
pcm.!default {
    type plug
    slave.pcm {
        type dmix
        ipc_key 1024
        slave {
            pcm "hw:0,0"
            period_size 2048
            buffer_size 16384
        }
    }
}
```

### Out of space during pip install

Make sure `/tmp` isn't a small tmpfs and the root partition has enough free space
(`df -h /`); pip needs scratch space to build wheels like numpy from source.

### USB DAC not detected

- Check USB connection
- Try different USB port
- Check: `dmesg | grep -i usb`
- Check: `lsusb`

### Service won't start

- Check logs: `journalctl -u sendspin -e`
- Test manually: `sendspin --headless`
- Verify the unit file: `systemctl cat sendspin`

## Next Steps

Once you have a working system:
1. Test thoroughly with your USB DAC
2. Configure WiFi if needed: `sudo nmtui`
3. Change default passwords
4. Consider creating an image backup of your SD card
