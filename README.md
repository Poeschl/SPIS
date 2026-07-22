# SASS

Simple Alpine SendSpin

A minimal Alpine Linux image for Raspberry Pi that runs [SendSpin](https://github.com/Sendspin/sendspin-cli) - a high-quality audio streaming protocol for Home Assistant's Music Assistant.

## Features

- **Minimal footprint** - Runs Alpine Linux in sys mode with only essential packages
- **Onboard audio by default** - Uses the Raspberry Pi's 3.5mm headphone jack out of the box, no extra hardware required
- **Optional USB DAC support** - Switch to a USB audio device via `/etc/asound.conf` if you want higher-quality output
- **Auto-start service** - SendSpin starts automatically on boot in headless mode
- **Low latency** - Direct ALSA hardware access for minimal audio buffering
- **Raspberry Pi optimized** - Built specifically for Pi 3/4 hardware

## Supported Hardware

- Raspberry Pi 3 Model B / B+
- Raspberry Pi 4 Model B
- Onboard 3.5mm headphone jack (default output)
- USB Audio DACs (optional, USB Audio Class compliant devices)

## Quick Start

### Download Pre-built Image

Download the latest image from [Releases](https://github.com/Poeschl/SAS/releases)

### Flash to SD Card

**Linux/macOS:**
```bash
dd if=sass-0.1.0-armv7.img of=/dev/sdX bs=4M status=progress
sync
```

**Windows:**
Use [Rufus](https://rufus.ie/)

### First Boot

1. Insert SD card into Raspberry Pi
2. (Optional) Connect a USB DAC if you don't want to use the onboard headphone jack
3. Power on
4. The player will automatically connect to Music Assistant on your network
5. Default credentials: `root` / `alpine` (change immediately!)

## Building from Source

### Automated Build (GitHub Actions)

Every tagged push (`v*`) triggers `.github/workflows/build-image.yml`, which builds a ready-to-flash image and publishes it as a GitHub Release:

- `sass-<version>-armv7.img.xz` - the flashable image
- `sass-<version>-armv7-CREDENTIALS.txt` - the random root password generated for that build (you'll be forced to change it on first login)
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

**WiFi:** SSH into the device and configure:
```bash
setup-interfaces
rc-service networking restart
```

### Hostname

```bash
setup-hostname mynewname
rc-service hostname restart
```

### Audio Device

By default, the system uses the onboard 3.5mm headphone jack (ALSA card `Headphones`). To use a USB DAC or another device instead:

1. List audio devices: `aplay -l`
2. Edit `/etc/asound.conf` and change `Headphones` to your device's card name or number
3. Restart sendspin: `rc-service sendspin restart`

## Project Structure

```
SASS/
├── build.sh                    # Main build script (creates the SD card image)
├── .github/workflows/
│   └── build-image.yml         # CI: builds + releases the image on tag push
├── config/
│   ├── packages.txt            # Top-level list of packages to install
│   ├── build-deps.txt          # Build-only packages removed in slim builds
│   └── setup-chroot.sh         # Non-interactive install, run inside the chroot
├── card_skeleton/               # Mirrors the target rootfs 1:1, rsync'd onto
│   │                            # the image as-is (paths below == final paths)
│   ├── etc/
│   │   ├── apk/repositories     # branch placeholder substituted at build time
│   │   ├── network/interfaces   # DHCP on eth0
│   │   ├── init.d/sendspin      # OpenRC service script
│   │   ├── asound.conf          # ALSA audio configuration
│   │   └── fstab                #
│   └── boot/
│       ├── config.txt           # Raspberry Pi boot config
│       └── cmdline.txt          #
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
rc-service sendspin status

# View logs
cat /var/log/messages | grep sendspin

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
- [Alpine Linux](https://alpinelinux.org/) 
- [Home Assistant](https://www.home-assistant.io/) and [Music Assistant](https://music-assistant.io/)
