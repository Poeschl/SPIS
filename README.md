# SPIS

Simple PI SendSpin

A minimal Raspberry Pi OS Lite image for Raspberry Pi that runs [SendSpin](https://github.com/Sendspin/sendspin-cli) - a high-quality audio streaming protocol for Home Assistant's Music Assistant.

## Features

- **Minimal footprint** - Built on Raspberry Pi OS Lite with only essential packages installed
- **Onboard audio by default** - Uses the Raspberry Pi's 3.5mm headphone jack out of the box, no extra hardware required
- **Optional USB DAC support** - Switch to a USB audio device via `/etc/asound.conf` if you want higher-quality output
- **Auto-start service** - SendSpin starts automatically on boot in headless mode via systemd
- **Low latency** - Direct ALSA hardware access for minimal audio buffering
- **Raspberry Pi optimized** - Built specifically for Pi 3/4 hardware

## Supported Hardware

- Raspberry Pi 3 Model B / B+
- Raspberry Pi 4 Model B
- Onboard 3.5mm headphone jack (default output)
- USB Audio DACs (optional, USB Audio Class compliant devices)

## Quick Start

### Download Pre-built Image

Download the latest image from [Releases](https://github.com/Poeschl/SPIS/releases)

Look out for the `*.img.xz` files. The `*.CREDENTIALS.txt` files contains the initial root password.

### Flash to SD Card

#### Linux / MacOS

```bash
dd if=spis-0.1.0-aarch64.img of=/dev/sdX bs=4M status=progress
sync
```

Or [Raspberry PI Imager](https://www.raspberrypi.com/software/)

#### Windows

Use [Rufus](https://rufus.ie/) or the [Raspberry PI Imager](https://www.raspberrypi.com/software/)

### First Boot

1. Insert SD card into Raspberry Pi
2. (Optional) Connect a USB DAC if you don't want to use the onboard headphone jack
3. Power on
4. The player will automatically connect to Music Assistant on your network
5. Default credentials: `root` / a randomly generated password published alongside the release as `*-CREDENTIALS.txt` (change immediately!)

## Building from Source

### Automated Build (GitHub Actions)

Every tagged push (`v*`) triggers `.github/workflows/build-image.yml`, which builds a ready-to-flash image and publishes it as a GitHub Release:

- `spis-<version>-aarch64.img.xz` - the flashable image
- `spis-<version>-aarch64-CREDENTIALS.txt` - the random root password generated for that build (you'll be forced to change it on first login)
- `version-info` - build version metadata

### Manual Installation

See [INSTALL.md](INSTALL.md) for complete step-by-step instructions to build your own image from scratch.

This method is recommended if you want to:
- Customize the installation
- Understand how the system works
- Build for different hardware configurations
- Troubleshoot issues

## Configuration

### Network Configuration

**Ethernet:** Works automatically via DHCP

**WiFi:** SSH into the device and configure via the points below

### Enabling WiFi

1. SSH into the device (via Ethernet, or a monitor/keyboard connected directly)
2. Set the WiFi country (required before the radio can be used, see [Troubleshooting](#wi-fi-blocked-by-rfkill) below):
   ```bash
   sudo raspi-config
   ```
   Navigate to `5 Localisation Options` → `L4 WLAN Country` and select your country.
3. Connect to a network using `nmtui` (interactive) or `nmcli`:
   ```bash
   sudo nmtui
   # or non-interactively:
   sudo nmcli device wifi connect "SSID" password "your-password"
   ```
4. Verify the connection:
   ```bash
   nmcli device status
   ip a
   ```

### Hostname

```bash
hostnamectl set-hostname mynewname
```

### Audio Device

By default, the system uses the onboard 3.5mm headphone jack (ALSA card `Headphones`). To use a USB DAC or another device instead:

1. List audio devices: `aplay -l`
2. Edit `/etc/asound.conf` and change the config to your device's card number
3. Restart sendspin: `systemctl restart sendspin`

## Project Structure

```
SPIS/
├── build.sh                    # Main build script (downloads + customizes the SD card image)
├── .github/workflows/
│   └── build-image.yml         # CI: builds + releases the image on tag push
├── config/
│   ├── packages.txt            # Top-level list of apt packages to install
│   ├── build-deps.txt          # Build-only apt packages removed in slim builds
│   ├── config-append.txt       # Audio/boot tuning appended to config.txt
│   └── setup-chroot.sh         # Non-interactive install, run inside the chroot
├── card_skeleton/               # Mirrors the target rootfs 1:1, rsync'd onto
│   │                            # the image as-is (paths below == final paths)
│   └── etc/
│       ├── systemd/system/sendspin.service  # systemd service for sendspin
│       └── asound.conf          # ALSA audio configuration
└── dist/                       # Build artifacts (.img.xz, credentials)
```

## Troubleshooting

### Audio Issues (Pops/Crackles)

Check buffer settings in `/etc/asound.conf`. Increase buffer_size if needed:
```
buffer_size 16384
```

### SendSpin Not Starting

```bash
# Check service status
systemctl status sendspin

# View logs
journalctl -u sendspin -e

# Manual test
sendspin --headless
```

### USB DAC Not Detected

```bash
# List USB devices
lsusb

# Check ALSA devices
aplay -l

# Check kernel messages
dmesg | grep -i audio
```

## Credits

- [Tycho-MEC/SASS](https://github.com/Tycho-MEC/SASS) for the base of this fork
- [SendSpin](https://github.com/Sendspin/sendspin-cli) by the SendSpin team
- [Raspberry Pi OS](https://www.raspberrypi.com/software/)
- [Home Assistant](https://www.home-assistant.io/) and [Music Assistant](https://music-assistant.io/)
