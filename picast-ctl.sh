#!/bin/bash
# =============================================================================
# Cutegory PiCast — Remote management CLI
# Usage: picast-ctl.sh <command> [args]
# =============================================================================

set -euo pipefail

INSTALL_DIR="/opt/picast"
SERVICE="picast"

case "${1:-help}" in
  status)
    echo "=== PiCast Status ==="
    systemctl status "$SERVICE" --no-pager 2>/dev/null | head -10
    echo ""
    echo "=== Device Info ==="
    echo "Hostname:  $(hostname)"
    echo "IP (LAN):  $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "IP (TS):   $(tailscale ip -4 2>/dev/null || echo 'n/a')"
    echo "Uptime:    $(uptime -p)"
    echo "Disk:      $(df -h / | awk 'NR==2{printf "%s used / %s (%s)", $3, $2, $5}')"
    echo "RAM:       $(free -h | awk '/Mem/{printf "%s used / %s", $3, $2}')"
    echo ""
    echo "=== Player ==="
    "$INSTALL_DIR/player.sh" status 2>/dev/null || echo "Not running"
    echo ""
    echo "=== Last Sync ==="
    if [ -f "$INSTALL_DIR/.last-sync.json" ]; then
      jq -r '"Playlist: " + (.playlist.name // "none") + " (source: " + (.playlist.source // "none") + ")\nItems: " + (.items | length | tostring)' "$INSTALL_DIR/.last-sync.json" 2>/dev/null
    else
      echo "No sync data"
    fi
    echo "Config hash: $(cat "$INSTALL_DIR/.last-hash" 2>/dev/null || echo 'none')"
    ;;

  logs)
    journalctl -u "$SERVICE" --no-pager -n "${2:-50}"
    ;;

  logs-follow)
    journalctl -u "$SERVICE" -f
    ;;

  restart)
    echo "Restarting PiCast..."
    sudo systemctl restart "$SERVICE"
    echo "Done. Status:"
    sleep 2
    systemctl status "$SERVICE" --no-pager | head -5
    ;;

  stop)
    echo "Stopping PiCast..."
    sudo systemctl stop "$SERVICE"
    echo "Stopped."
    ;;

  start)
    echo "Starting PiCast..."
    sudo systemctl start "$SERVICE"
    echo "Started."
    ;;

  update)
    echo "Running self-update..."
    sudo "$INSTALL_DIR/self-update.sh"
    ;;

  sync)
    echo "=== Current Sync Response ==="
    source "$INSTALL_DIR/config.env"
    curl -sf "${SERVER_URL}/api/v1/signage/sync/${DEVICE_ID}" \
      -H "X-Device-Token: ${DEVICE_KEY}" | jq .
    ;;

  media)
    echo "=== Local Media Files ==="
    ls -lh "$INSTALL_DIR/media/" 2>/dev/null || echo "No media files"
    echo ""
    echo "Total: $(du -sh "$INSTALL_DIR/media/" 2>/dev/null | cut -f1 || echo '0')"
    ;;

  tv-on)
    "$INSTALL_DIR/cec-control.sh" on
    ;;

  tv-off)
    "$INSTALL_DIR/cec-control.sh" off
    ;;

  tv-status)
    "$INSTALL_DIR/cec-control.sh" status
    ;;

  reboot)
    echo "Rebooting Pi..."
    sudo reboot
    ;;

  help|*)
    cat << 'HELP'
Cutegory PiCast — Remote Management

Usage: picast-ctl <command>

Commands:
  status        Full system status (service, device, player, sync)
  logs [N]      Show last N log lines (default 50)
  logs-follow   Follow logs in real-time
  restart       Restart PiCast service
  stop          Stop PiCast service
  start         Start PiCast service
  update        Run self-update from GitHub
  sync          Show current sync response from server
  media         List local media files
  tv-on         Turn TV on via HDMI CEC
  tv-off        Turn TV off via HDMI CEC
  tv-status     Check TV power status
  reboot        Reboot Raspberry Pi
  help          Show this help
HELP
    ;;
esac
