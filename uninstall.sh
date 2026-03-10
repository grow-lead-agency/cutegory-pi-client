#!/bin/bash
# =============================================================================
# Cutegory PiCast — Complete uninstaller
# Usage: sudo ./uninstall.sh
# =============================================================================

set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] This script must be run as root (sudo ./uninstall.sh)"
  exit 1
fi

echo "========================================="
echo "  Cutegory PiCast Uninstaller"
echo "========================================="

echo "[1/5] Stopping services..."
systemctl stop picast.service 2>/dev/null || true
systemctl stop picast-update.timer 2>/dev/null || true
systemctl disable picast.service 2>/dev/null || true
systemctl disable picast-update.timer 2>/dev/null || true

echo "[2/5] Removing systemd units..."
rm -f /etc/systemd/system/picast.service
rm -f /etc/systemd/system/picast-update.service
rm -f /etc/systemd/system/picast-update.timer
systemctl daemon-reload

echo "[3/5] Removing files..."
rm -rf /opt/picast
rm -f /usr/local/bin/picast-ctl
echo "  Removed /opt/picast and /usr/local/bin/picast-ctl"

echo "[4/5] Removing cron jobs..."
(crontab -l 2>/dev/null | grep -v '/sbin/reboot' | grep -v 'picast') | crontab - 2>/dev/null || true

echo "[5/5] Removing user..."
userdel picast 2>/dev/null || true
echo "  Removed user picast"

echo ""
echo "PiCast uninstalled."
echo ""
echo "NOT removed (manual cleanup if needed):"
echo "  - Tailscale (/usr/bin/tailscale)"
echo "  - UFW firewall rules"
echo "  - fail2ban"
echo "  - Boot config changes in /boot/firmware/config.txt"
echo "  - SSH config changes"
