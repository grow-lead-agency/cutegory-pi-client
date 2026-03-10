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
apt-get install -y -qq mpv jq curl cec-utils git edid-decode fbgrab chromium xserver-xorg-core xinit unclutter

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

# [4/8] Copy client files
echo "[4/8] Copying client files..."
cp "$SCRIPT_DIR/picast-client.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/sync.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/player.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/cec-control.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/picast-ctl.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/display-detect.sh" "$INSTALL_DIR/"

chmod +x "$INSTALL_DIR"/*.sh

# Symlink picast-ctl to PATH for easy access
ln -sf "$INSTALL_DIR/picast-ctl.sh" /usr/local/bin/picast-ctl

# Copy config — prefer real config.env over template, never overwrite existing
if [ ! -f "$INSTALL_DIR/config.env" ]; then
  if [ -f "$SCRIPT_DIR/config.env" ]; then
    cp "$SCRIPT_DIR/config.env" "$INSTALL_DIR/config.env"
    echo "  Copied config.env"
  else
    cp "$SCRIPT_DIR/config.env.example" "$INSTALL_DIR/config.env"
    echo "  Created config.env from template — EDIT THIS FILE!"
  fi
else
  echo "  config.env already exists, skipping"
fi

# Copy assets (standby screen, test pages)
if [ -d "$SCRIPT_DIR/assets" ]; then
  mkdir -p "$INSTALL_DIR/assets"
  cp -r "$SCRIPT_DIR/assets/"* "$INSTALL_DIR/assets/" 2>/dev/null || true
  echo "  Copied assets (standby screen, test pages)"
fi

# Set ownership
chown -R picast:picast "$INSTALL_DIR"

# Copy self-update script
if [ -f "$SCRIPT_DIR/self-update.sh" ]; then
  cp "$SCRIPT_DIR/self-update.sh" "$INSTALL_DIR/"
  chmod +x "$INSTALL_DIR/self-update.sh"
fi

# [5/8] Install systemd services
echo "[5/8] Installing systemd services..."
cp "$SCRIPT_DIR/systemd/picast.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/picast-update.service" /etc/systemd/system/ 2>/dev/null || true
cp "$SCRIPT_DIR/systemd/picast-update.timer" /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload

# Enable auto-update timer
systemctl enable picast-update.timer 2>/dev/null || true
systemctl start picast-update.timer 2>/dev/null || true
echo "  Auto-update: daily at 04:00 + on boot"

# Weekly reboot for reliability (Sunday 03:30)
echo "  Adding weekly reboot (Sunday 03:30)..."
CRON_LINE="30 3 * * 0 /sbin/reboot"
(crontab -l 2>/dev/null | grep -v '/sbin/reboot'; echo "$CRON_LINE") | crontab -
echo "  Weekly reboot: Sunday 03:30"

# [6/8] Security hardening
echo "[6/8] Security hardening..."

# Install and configure UFW firewall
if ! command -v ufw &>/dev/null; then
  apt-get install -y -qq ufw
fi
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow ssh >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
echo "  Firewall: SSH only inbound"

# Install fail2ban
if ! command -v fail2ban-client &>/dev/null; then
  apt-get install -y -qq fail2ban
  systemctl enable fail2ban
  systemctl start fail2ban
fi
echo "  fail2ban: SSH brute force protection"

# Disable unused services
systemctl disable bluetooth.service 2>/dev/null || true
systemctl disable avahi-daemon.service 2>/dev/null || true
echo "  Disabled: bluetooth, avahi"

# Disable SSH password auth (key-only via Tailscale)
if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
  systemctl reload sshd 2>/dev/null || true
  echo "  SSH: password auth disabled (key-only)"
fi

# Restrict config.env permissions (contains device secrets)
chmod 600 "$INSTALL_DIR/config.env" 2>/dev/null || true
echo "  config.env: owner-only read (600)"

# Enable unattended security updates
if ! dpkg -l unattended-upgrades &>/dev/null; then
  apt-get install -y -qq unattended-upgrades
  echo 'Unattended-Upgrade::Origins-Pattern { "origin=Debian,codename=${distro_codename},label=Debian-Security"; };' \
    > /etc/apt/apt.conf.d/51picast-auto-security
  echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> /etc/apt/apt.conf.d/51picast-auto-security
  systemctl enable unattended-upgrades
  echo "  Unattended security updates: enabled"
fi

# [7/8] Configure boot for signage
echo "[7/8] Configuring boot..."

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
disable_splash=1
HDMI
  echo "  Added HDMI config to $BOOT_CONFIG"
fi

# Hide boot text — show blank screen instead of console messages
CMDLINE="/boot/firmware/cmdline.txt"
[ ! -f "$CMDLINE" ] && CMDLINE="/boot/cmdline.txt"
if ! grep -q "quiet" "$CMDLINE" 2>/dev/null; then
  sed -i 's/$/ quiet splash loglevel=0 logo.nologo vt.global_cursor_default=0/' "$CMDLINE"
  echo "  Hidden boot text (quiet splash)"
fi

# [8/8] Enable service (don't start yet — config needed)
echo "[8/8] Enabling service..."
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
