# SendSpin RaspiOS - Manual Installation Guide

This guide walks you through installing SendSpin on Raspberry Pi OS Lite from scratch. This is useful for:
- Building your own custom image
- Understanding how the system works
- Troubleshooting issues
- Creating variations for different hardware

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

```bash
sudo apt-get install -y python3 python3-pip python3-venv alsa-utils libasound2
```

## Step 6: Install Build Dependencies

These are needed to compile Python packages:

```bash
sudo apt-get install -y gcc python3-dev build-essential libopenblas-dev gfortran \
    libavformat-dev libavcodec-dev libavdevice-dev libavutil-dev libswscale-dev \
    libswresample-dev pkg-config libffi-dev libjpeg-dev zlib1g-dev \
    portaudio19-dev libportaudio2
```

## Step 7: Install SendSpin

```bash
sudo pip install --break-system-packages sendspin
```

This will take 10-20 minutes on a Raspberry Pi 3 as it compiles numpy and other packages.

**Note:** The `--break-system-packages` flag is needed because Debian/RaspiOS marks the
system Python as externally managed (PEP 668). This is safe for a dedicated appliance.

## Step 8: Add SendSpin to PATH

If installing as root (as above), sendspin is installed to `/usr/local/bin` and is
already on `PATH`. If installing as a non-root user instead:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
source ~/.profile
```

## Step 9: Configure USB Audio

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

## Step 10: Create SendSpin Service

Create the systemd unit:

```bash
sudo nano /etc/systemd/system/sendspin.service
```

Add this content:

```ini
[Unit]
Description=SendSpin Audio Player
Documentation=https://github.com/Sendspin/sendspin-cli
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sendspin --headless
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
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

## Step 11: Optional - Configure doas as a sudo alternative

For easier administration:

```bash
sudo apt-get install -y doas

# Configure doas
echo "permit persist :sudo" | sudo tee /etc/doas.conf

# Add a user (if desired)
sudo adduser yourname
sudo usermod -aG sudo yourname
```

## Step 12: Test SendSpin

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

## Step 13: Cleanup (Optional)

If you want to reduce image size, you can remove build dependencies after sendspin is installed:

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
