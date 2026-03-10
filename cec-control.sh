#!/bin/bash
# =============================================================================
# Cutegory PiCast — HDMI CEC TV control
# Turns TV on/off via cec-client (libCEC)
# Requires: sudo apt-get install cec-utils
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${PICAST_CONFIG:-$SCRIPT_DIR/config.env}"
# shellcheck source=config.env.example
source "$CONFIG_FILE"

CEC_DEVICE="${CEC_DEVICE:-0}"
ACTION="${1:-}"

# Check if cec-client is available
if ! command -v cec-client &>/dev/null; then
  echo "[cec] WARN: cec-client not found, skipping TV control"
  echo "[cec] Install with: sudo apt-get install cec-utils"
  exit 0
fi

case "$ACTION" in
  on)
    echo "[cec] Turning TV ON"
    echo "on $CEC_DEVICE" | cec-client -s -d 1 2>/dev/null || echo "[cec] WARN: CEC on command failed"
    # Switch to Pi HDMI input
    sleep 2
    echo "as" | cec-client -s -d 1 2>/dev/null || true
    ;;
  off)
    echo "[cec] Turning TV OFF (standby)"
    echo "standby $CEC_DEVICE" | cec-client -s -d 1 2>/dev/null || echo "[cec] WARN: CEC standby command failed"
    ;;
  status)
    echo "[cec] Querying TV power status..."
    echo "pow $CEC_DEVICE" | cec-client -s -d 1 2>/dev/null || echo "[cec] WARN: CEC status query failed"
    ;;
  *)
    echo "Usage: $0 {on|off|status}"
    exit 1
    ;;
esac
