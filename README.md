# Cutegory PiCast

Open-source digital signage client for Raspberry Pi 4. Polls a backoffice API, downloads media, and plays content fullscreen via mpv/Chromium.

## Features

- **Media playback** — images + videos via mpv (DRM direct, no X11 needed)
- **Web content** — URLs via Chromium kiosk (hybrid mode with Xorg)
- **HEVC/H.264** — hardware-accelerated decoding on Pi 4
- **4K support** — auto-detects display resolution, HDR, aspect ratio
- **Offline resilient** — cached config + media, SHA-256 verification
- **Display power** — CEC (TVs) + DDC/CI (monitors) with working hours
- **OTA updates** — automatic daily updates from GitHub
- **Remote management** — command queue (reboot, screenshot, CEC test)
- **Security** — UFW, fail2ban, SSH key-only, Tailscale VPN

## Requirements

- Raspberry Pi 4 (ARM64)
- Pi OS Lite 64-bit (Debian Bookworm/Trixie)
- HDMI display (TV or monitor)
- Network connection (WiFi or Ethernet)

## Quick Start

```bash
# Clone and install
git clone https://github.com/grow-lead-agency/cutegory-pi-client.git
cd cutegory-pi-client
sudo ./install.sh

# Configure
sudo nano /opt/picast/config.env
# Set DEVICE_ID and DEVICE_KEY from backoffice

# Connect remote access
sudo tailscale up --hostname=picast-XXX

# Start
sudo systemctl start picast
sudo reboot
```

## Architecture

```
picast-client.sh    Main daemon (30s poll loop)
├── sync.sh         Media download (R2 CDN, SHA-256, staging dir)
├── player.sh       Playback orchestrator (mpv DRM / Xorg hybrid)
├── cec-control.sh  Display power (CEC first, DDC/CI fallback)
├── display-detect.sh  EDID parsing, resolution detection
└── self-update.sh  OTA updates from GitHub tarball
```

## Management

```bash
picast-ctl status       # Full system status
picast-ctl logs         # Last 50 log lines
picast-ctl logs-follow  # Real-time logs
picast-ctl restart      # Restart service
picast-ctl sync         # Show current sync response
picast-ctl media        # List local media files
picast-ctl display      # Display info (resolution, model, 4K, HDR)
picast-ctl tv-on        # Turn display on (CEC/DDC)
picast-ctl tv-off       # Turn display off (CEC/DDC)
picast-ctl update       # Manual update from GitHub
picast-ctl reboot       # Reboot Pi
```

## Configuration

See [config.env.example](config.env.example) for all options.

## Uninstall

```bash
sudo ./uninstall.sh
```
