#!/bin/bash
# =============================================================================
# Cutegory PiCast — Display power control
# Strategy: CEC first (for TVs), DDC/CI fallback (for monitors)
# CEC requires: sudo apt-get install cec-utils
# DDC requires: sudo apt-get install ddcutil + i2c-dev module
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${PICAST_CONFIG:-$SCRIPT_DIR/config.env}"
# shellcheck source=config.env.example
source "$CONFIG_FILE"

CEC_DEVICE="${CEC_DEVICE:-0}"
ACTION="${1:-}"
BRIGHTNESS_FILE="$SCRIPT_DIR/.saved-brightness"

# ---------- DDC/CI helpers ----------

ddc_available() {
  command -v ddcutil &>/dev/null
}

ddc_set_brightness() {
  local value="$1"
  sudo ddcutil setvcp 10 "$value" 2>/dev/null
}

ddc_get_brightness() {
  sudo ddcutil getvcp 10 2>/dev/null | grep -oP 'current value =\s+\K\d+'
}

ddc_off() {
  # Try power mode D6 first (proper standby)
  if sudo ddcutil setvcp d6 4 2>/dev/null; then
    echo "[display] DDC: standby via power mode"
    return 0
  fi
  # Fallback: save brightness and set to 0
  local current
  current=$(ddc_get_brightness) || current="100"
  echo "$current" > "$BRIGHTNESS_FILE"
  ddc_set_brightness 0
  echo "[display] DDC: brightness → 0 (saved: $current)"
}

ddc_on() {
  # Try power mode D6 first
  if sudo ddcutil setvcp d6 1 2>/dev/null; then
    echo "[display] DDC: wake via power mode"
    return 0
  fi
  # Fallback: restore saved brightness
  local saved="100"
  if [ -f "$BRIGHTNESS_FILE" ]; then
    saved=$(cat "$BRIGHTNESS_FILE")
    rm -f "$BRIGHTNESS_FILE"
  fi
  ddc_set_brightness "$saved"
  echo "[display] DDC: brightness → $saved"
}

ddc_status() {
  local bright
  bright=$(ddc_get_brightness) || bright="unknown"
  echo "[display] DDC: brightness=$bright"
}

# ---------- CEC helpers ----------

cec_available() {
  command -v cec-client &>/dev/null
}

try_cec() {
  local cmd="$1"
  local result
  result=$(echo "$cmd" | timeout 10 cec-client -s -d 1 2>&1) || true
  # Check if CEC actually works (no TRANSMIT errors)
  if echo "$result" | grep -q "CEC_TRANSMIT failed"; then
    return 1
  fi
  return 0
}

# ---------- main ----------

case "$ACTION" in
  on)
    if cec_available && try_cec "pow $CEC_DEVICE"; then
      echo "[display] CEC: turning ON"
      echo "on $CEC_DEVICE" | cec-client -s -d 1 2>/dev/null || true
      sleep 2
      echo "as" | cec-client -s -d 1 2>/dev/null || true
    elif ddc_available; then
      ddc_on
    else
      echo "[display] WARN: No CEC or DDC available"
    fi
    ;;
  off)
    if cec_available && try_cec "pow $CEC_DEVICE"; then
      echo "[display] CEC: turning OFF (standby)"
      echo "standby $CEC_DEVICE" | cec-client -s -d 1 2>/dev/null || true
    elif ddc_available; then
      ddc_off
    else
      echo "[display] WARN: No CEC or DDC available"
    fi
    ;;
  status)
    if cec_available && try_cec "pow $CEC_DEVICE"; then
      echo "[display] CEC: querying power status"
      echo "pow $CEC_DEVICE" | cec-client -s -d 1 2>/dev/null || true
    elif ddc_available; then
      ddc_status
    else
      echo "[display] WARN: No CEC or DDC available"
    fi
    ;;
  *)
    echo "Usage: $0 {on|off|status}"
    exit 1
    ;;
esac
