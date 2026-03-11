#!/bin/bash
# =============================================================================
# Cutegory PiCast — One-click installer for Raspberry Pi
# Tested on: Raspberry Pi 4 + Pi OS Lite 64-bit (Debian Trixie/Bookworm)
# Usage: scp this repo to Pi, then run: sudo ./install.sh
# =============================================================================

set -e

PICAST_VERSION="1.2.0"
INSTALL_DIR="/opt/picast"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  Cutegory PiCast Installer v${PICAST_VERSION}"
echo "========================================="

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] This script must be run as root (sudo ./install.sh)"
  exit 1
fi

# Check if running on Raspberry Pi
if ! grep -q "Raspberry\|BCM" /proc/cpuinfo 2>/dev/null; then
  echo "[WARN] This doesn't appear to be a Raspberry Pi. Continuing anyway..."
fi

# =========================================================================
# [1/9] Install dependencies
# =========================================================================
echo ""
echo "[1/9] Installing dependencies..."
apt-get update -qq

# Core
apt-get install -y -qq \
  mpv jq curl socat \
  cec-utils \
  ddcutil \
  git \
  edid-decode \
  ffmpeg

# Chromium + Xorg (for hybrid web content playback)
apt-get install -y -qq \
  chromium \
  xserver-xorg-core xserver-xorg-legacy xinit \
  unclutter dbus-x11 x11-xserver-utils

echo "  Core: mpv, jq, curl, cec-utils, ddcutil, ffmpeg, chromium"

# =========================================================================
# [2/9] Create picast user + groups
# =========================================================================
echo "[2/9] Creating picast user..."
if ! id picast &>/dev/null; then
  useradd -r -m -s /bin/bash -d /home/picast picast
  echo "  Created user: picast (home: /home/picast)"
else
  echo "  User picast already exists"
  # Ensure home dir exists (Chromium + shader cache need it)
  mkdir -p /home/picast/.cache
  chown -R picast:picast /home/picast
fi

# Add to required groups for hardware access
usermod -aG video picast   # DRM/GPU access
usermod -aG render picast  # GPU render nodes (/dev/dri/renderD128)
usermod -aG input picast   # Input devices
usermod -aG tty picast     # VT access (Xorg needs /dev/tty7)
usermod -aG i2c picast 2>/dev/null || true  # DDC/CI (i2c bus)
echo "  Groups: video, render, input, tty, i2c"

# Enable i2c-dev kernel module (required for ddcutil / DDC/CI)
if ! grep -q "^i2c-dev" /etc/modules 2>/dev/null; then
  echo "i2c-dev" >> /etc/modules
  modprobe i2c-dev 2>/dev/null || true
  echo "  Enabled i2c-dev kernel module"
fi

# =========================================================================
# [3/9] Create directories
# =========================================================================
echo "[3/9] Creating directories..."
mkdir -p "$INSTALL_DIR"/{media,logs,assets}

# mpv shader cache dir (prevents permission errors)
mkdir -p "$INSTALL_DIR/.cache"

# =========================================================================
# [4/9] Copy client files
# =========================================================================
echo "[4/9] Copying client files..."
for script in picast-client.sh sync.sh player.sh cec-control.sh picast-ctl.sh display-detect.sh self-update.sh; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/$script"
    chmod +x "$INSTALL_DIR/$script"
  fi
done
echo "  Scripts: $(ls "$INSTALL_DIR"/*.sh 2>/dev/null | wc -l) files"

# Symlink picast-ctl to PATH for easy access
ln -sf "$INSTALL_DIR/picast-ctl.sh" /usr/local/bin/picast-ctl
echo "  Symlink: /usr/local/bin/picast-ctl → picast-ctl.sh"

# Copy config — prefer real config.env over template, NEVER overwrite existing
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

# Copy assets (standby screen, updating splash, test pages)
if [ -d "$SCRIPT_DIR/assets" ]; then
  cp -r "$SCRIPT_DIR/assets/"* "$INSTALL_DIR/assets/" 2>/dev/null || true
  echo "  Assets: standby.jpg, updating.jpg, test-web.html"
fi

# Set ownership (all picast files owned by picast user)
chown -R picast:picast "$INSTALL_DIR"

# =========================================================================
# [5/9] Install systemd services
# =========================================================================
echo "[5/9] Installing systemd services..."
cp "$SCRIPT_DIR/systemd/picast.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/picast-update.service" /etc/systemd/system/ 2>/dev/null || true
cp "$SCRIPT_DIR/systemd/picast-update.timer" /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload

# Enable auto-update timer (daily at 04:00 + 60s after boot)
systemctl enable picast-update.timer 2>/dev/null || true
systemctl start picast-update.timer 2>/dev/null || true
echo "  Auto-update: daily at 04:00 + on boot"

# Weekly reboot for reliability (Sunday 03:30)
CRON_LINE="30 3 * * 0 /sbin/reboot"
(crontab -l 2>/dev/null | grep -v '/sbin/reboot'; echo "$CRON_LINE") | crontab -
echo "  Weekly reboot: Sunday 03:30"

# =========================================================================
# [6/9] Security hardening
# =========================================================================
echo "[6/9] Security hardening..."

# UFW firewall
if ! command -v ufw &>/dev/null; then
  apt-get install -y -qq ufw
fi
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow ssh >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
echo "  Firewall: SSH only inbound"

# fail2ban
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

# SSH key-only auth (skip if no authorized_keys yet — let user add key first)
if [ -f /home/picast/.ssh/authorized_keys ] 2>/dev/null || [ -f "$INSTALL_DIR/.ssh/authorized_keys" ] 2>/dev/null; then
  if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || true
    echo "  SSH: password auth disabled (key-only)"
  fi
else
  echo "  SSH: password auth kept (no authorized_keys found — add SSH key first!)"
fi

# Restrict config.env permissions (contains device secrets)
chmod 600 "$INSTALL_DIR/config.env" 2>/dev/null || true
echo "  config.env: owner-only read (600)"

# Unattended security updates
if ! dpkg -l unattended-upgrades &>/dev/null 2>&1; then
  apt-get install -y -qq unattended-upgrades
  cat > /etc/apt/apt.conf.d/51picast-auto-security << 'APTCONF'
Unattended-Upgrade::Origins-Pattern { "origin=Debian,codename=${distro_codename},label=Debian-Security"; };
Unattended-Upgrade::Automatic-Reboot "false";
APTCONF
  systemctl enable unattended-upgrades
  echo "  Unattended security updates: enabled"
fi

# =========================================================================
# [7/9] Install Tailscale (remote access VPN)
# =========================================================================
echo "[7/9] Setting up Tailscale..."
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
  echo "  Tailscale installed — run 'sudo tailscale up' to authenticate"
else
  echo "  Tailscale already installed"
  tailscale status 2>/dev/null | head -3 || echo "  (not connected)"
fi

# =========================================================================
# [8/9] Configure boot for signage
# =========================================================================
echo "[8/9] Configuring boot..."

# Auto-login to console (no desktop)
raspi-config nonint do_boot_behaviour B2 2>/dev/null || true

# GPU memory allocation
BOOT_CONFIG="/boot/firmware/config.txt"
[ ! -f "$BOOT_CONFIG" ] && BOOT_CONFIG="/boot/config.txt"

if ! grep -q "# PiCast settings" "$BOOT_CONFIG" 2>/dev/null; then
  cat >> "$BOOT_CONFIG" << 'HDMI'

# PiCast settings
hdmi_enable_4kp60=1
gpu_mem=256
disable_overscan=1
hdmi_force_hotplug=1
disable_splash=1
# Enable DRM VC4 driver (required for mpv DRM output)
dtoverlay=vc4-kms-v3d
HDMI
  echo "  Added HDMI + GPU config to $BOOT_CONFIG"
fi

# Hide boot text (blank screen instead of console messages)
CMDLINE="/boot/firmware/cmdline.txt"
[ ! -f "$CMDLINE" ] && CMDLINE="/boot/cmdline.txt"
if ! grep -q "quiet" "$CMDLINE" 2>/dev/null; then
  sed -i 's/$/ quiet splash loglevel=0 logo.nologo vt.global_cursor_default=0 consoleblank=1/' "$CMDLINE"
  echo "  Hidden boot text (quiet splash, console blank)"
fi

# Set VT7 console to black (prevents blue flash during mpv↔Chromium transitions)
cat > /etc/systemd/system/picast-vt-black.service << 'VTBLACK'
[Unit]
Description=Black out VT7 console for PiCast
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'setterm --background black --foreground black --clear all > /dev/tty7 2>/dev/null; echo -e "\033[?25l" > /dev/tty7 2>/dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
VTBLACK
systemctl daemon-reload
systemctl enable picast-vt-black.service 2>/dev/null || true
echo "  VT7 black console: enabled (systemd oneshot)"

# Xwrapper config (allow non-root Xorg + root rights for VT access)
mkdir -p /etc/X11
cat > /etc/X11/Xwrapper.config << 'XWRAP'
allowed_users=anybody
needs_root_rights=yes
XWRAP
echo "  Xwrapper: allowed_users=anybody, needs_root_rights=yes"

# =========================================================================
# [9/9] Enable service
# =========================================================================
echo "[9/9] Enabling PiCast service..."
systemctl enable picast.service

# =========================================================================
# Interactive setup (optional — skip with --non-interactive)
# =========================================================================
if [ "${1:-}" != "--non-interactive" ]; then
  echo ""
  echo "========================================="
  echo "  Interactive Setup"
  echo "========================================="

  # --- SSH key ---
  echo ""
  echo "  Paste your SSH public key (or press Enter to skip):"
  read -r SSH_KEY_INPUT
  if [ -n "$SSH_KEY_INPUT" ]; then
    # Create .ssh for picast user
    mkdir -p "$INSTALL_DIR/.ssh"
    echo "$SSH_KEY_INPUT" >> "$INSTALL_DIR/.ssh/authorized_keys"
    chmod 700 "$INSTALL_DIR/.ssh"
    chmod 600 "$INSTALL_DIR/.ssh/authorized_keys"
    chown -R picast:picast "$INSTALL_DIR/.ssh"
    # Also for the main user (pi/admin)
    MAIN_USER=$(logname 2>/dev/null || echo "pi")
    MAIN_HOME=$(eval echo "~$MAIN_USER")
    if [ -d "$MAIN_HOME" ]; then
      mkdir -p "$MAIN_HOME/.ssh"
      echo "$SSH_KEY_INPUT" >> "$MAIN_HOME/.ssh/authorized_keys"
      chmod 700 "$MAIN_HOME/.ssh"
      chmod 600 "$MAIN_HOME/.ssh/authorized_keys"
      chown -R "$MAIN_USER:$MAIN_USER" "$MAIN_HOME/.ssh"
    fi
    echo "  SSH key added for picast + $MAIN_USER"
    # Now safe to disable password auth
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || true
    echo "  SSH: password auth disabled (key-only)"
  fi

  # --- Device config ---
  echo ""
  echo "  Enter DEVICE_ID (UUID from backoffice, or press Enter to skip):"
  read -r INPUT_DEVICE_ID
  if [ -n "$INPUT_DEVICE_ID" ]; then
    sed -i "s|^DEVICE_ID=.*|DEVICE_ID=\"$INPUT_DEVICE_ID\"|" "$INSTALL_DIR/config.env"
    echo "  DEVICE_ID set"
  fi

  echo "  Enter DEVICE_KEY (secret token, or press Enter to skip):"
  read -r INPUT_DEVICE_KEY
  if [ -n "$INPUT_DEVICE_KEY" ]; then
    sed -i "s|^DEVICE_KEY=.*|DEVICE_KEY=\"$INPUT_DEVICE_KEY\"|" "$INSTALL_DIR/config.env"
    echo "  DEVICE_KEY set"
  fi

  # --- Hostname ---
  echo ""
  echo "  Enter hostname for this Pi (e.g. cutegory-prg-recepce, or Enter to skip):"
  read -r INPUT_HOSTNAME
  if [ -n "$INPUT_HOSTNAME" ]; then
    hostnamectl set-hostname "$INPUT_HOSTNAME"
    echo "  Hostname set to: $INPUT_HOSTNAME"
  fi
fi

echo ""
echo "========================================="
echo "  PiCast v${PICAST_VERSION} installed!"
echo ""
if [ -n "${INPUT_DEVICE_ID:-}" ] && [ -n "${INPUT_DEVICE_KEY:-}" ]; then
echo "  Config ready! Next:"
echo "  1. Connect Tailscale:"
echo "       sudo tailscale up --hostname=${INPUT_HOSTNAME:-picast-XXX}"
echo ""
echo "  2. Start + reboot:"
echo "       sudo systemctl start picast && sudo reboot"
else
echo "  Next steps:"
echo "  1. Edit config:"
echo "       sudo nano $INSTALL_DIR/config.env"
echo "     Set DEVICE_ID and DEVICE_KEY from backoffice"
echo ""
echo "  2. Connect Tailscale:"
echo "       sudo tailscale up --hostname=picast-XXX"
echo ""
echo "  3. Start PiCast:"
echo "       sudo systemctl start picast"
fi
echo ""
echo "  Monitor:"
echo "       journalctl -u picast -f"
echo "       picast-ctl status"
echo ""
echo "  Reboot (recommended):"
echo "       sudo reboot"
echo "========================================="
