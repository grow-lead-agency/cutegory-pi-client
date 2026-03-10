#!/bin/bash
# =============================================================================
# Cutegory PiCast — One-click installer for Raspberry Pi
# Usage: scp this repo to Pi, then run: sudo ./install.sh
# =============================================================================

set -e

echo "========================================="
echo "  Cutegory PiCast Installer"
echo "========================================="

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] This script must be run as root (sudo ./install.sh)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/picast"

# Check if running on Raspberry Pi
if ! grep -q "Raspberry\|BCM" /proc/cpuinfo 2>/dev/null; then
  echo "[WARN] This doesn't appear to be a Raspberry Pi. Continuing anyway..."
fi

# [1/7] Install dependencies
echo ""
echo "[1/7] Installing dependencies..."
apt-get update -qq
apt-get install -y -qq mpv jq curl cec-utils

# [2/7] Create picast user
echo "[2/7] Creating picast user..."
if ! id picast &>/dev/null; then
  useradd -r -s /usr/sbin/nologin -d "$INSTALL_DIR" picast
  # Add to video group for DRM/GPU access
  usermod -aG video picast
  echo "  Created user: picast"
else
  echo "  User picast already exists"
fi

# [3/7] Create directories
echo "[3/7] Creating directories..."
mkdir -p "$INSTALL_DIR"/{media,logs}

# [4/7] Copy client files
echo "[4/7] Copying client files..."
cp "$SCRIPT_DIR/picast-client.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/sync.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/player.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/cec-control.sh" "$INSTALL_DIR/"

chmod +x "$INSTALL_DIR"/*.sh

# Copy config if not exists (don't overwrite existing config)
if [ ! -f "$INSTALL_DIR/config.env" ]; then
  cp "$SCRIPT_DIR/config.env.example" "$INSTALL_DIR/config.env"
  echo "  Created config.env from template — EDIT THIS FILE!"
else
  echo "  config.env already exists, skipping"
fi

# Set ownership
chown -R picast:picast "$INSTALL_DIR"

# [5/7] Install systemd service
echo "[5/7] Installing systemd service..."
cp "$SCRIPT_DIR/systemd/picast.service" /etc/systemd/system/
systemctl daemon-reload

# [6/7] Configure boot for signage
echo "[6/7] Configuring boot..."

# Auto-login to console (no desktop)
raspi-config nonint do_boot_behaviour B2 2>/dev/null || true

# HDMI config for reliable output
BOOT_CONFIG="/boot/firmware/config.txt"
if [ ! -f "$BOOT_CONFIG" ]; then
  BOOT_CONFIG="/boot/config.txt"
fi

if ! grep -q "# PiCast settings" "$BOOT_CONFIG" 2>/dev/null; then
  cat >> "$BOOT_CONFIG" << 'HDMI'

# PiCast settings
hdmi_enable_4kp60=1
gpu_mem=256
disable_overscan=1
hdmi_force_hotplug=1
HDMI
  echo "  Added HDMI config to $BOOT_CONFIG"
fi

# [7/7] Enable service (don't start yet — config needed)
echo "[7/7] Enabling service..."
systemctl enable picast.service

echo ""
echo "========================================="
echo "  Installation complete!"
echo ""
echo "  Next steps:"
echo "  1. Edit $INSTALL_DIR/config.env"
echo "     - Set DEVICE_ID (from backoffice device registration)"
echo "     - Set DEVICE_KEY (shown after device registration)"
echo "  2. Start: sudo systemctl start picast"
echo "  3. Monitor: journalctl -u picast -f"
echo "  4. Reboot: sudo reboot"
echo "========================================="
