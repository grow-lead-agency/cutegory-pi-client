#!/bin/bash
# =============================================================================
# Cutegory PiCast — Uninstaller
# Usage: sudo ./uninstall.sh
# =============================================================================

set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] This script must be run as root (sudo ./uninstall.sh)"
  exit 1
fi

echo "Stopping PiCast..."
systemctl stop picast.service 2>/dev/null || true
systemctl disable picast.service 2>/dev/null || true
rm -f /etc/systemd/system/picast.service
systemctl daemon-reload

echo "Removing files..."
rm -rf /opt/picast

echo "Removing user..."
userdel picast 2>/dev/null || true

echo "PiCast uninstalled."
