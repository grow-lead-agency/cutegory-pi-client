#!/bin/bash
# =============================================================================
# Cutegory PiCast — Display detection & EDID info
# Detects connected display: resolution, model, HDR, refresh rate
# Uses kmsprint (DRM), tvservice (legacy), or edid-decode as fallback
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPLAY_CACHE="$SCRIPT_DIR/.display-info.json"

# ---------- detection methods ----------

detect_via_kmsprint() {
  # Modern DRM-based detection (Pi OS Bookworm+)
  if ! command -v kmsprint &>/dev/null; then
    return 1
  fi

  local output
  output=$(kmsprint 2>/dev/null) || return 1

  local width height refresh
  # Parse connected connector with mode info
  width=$(echo "$output" | grep -oP '\d+x\d+' | head -1 | cut -dx -f1)
  height=$(echo "$output" | grep -oP '\d+x\d+' | head -1 | cut -dx -f2)
  refresh=$(echo "$output" | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1)

  if [ -n "$width" ] && [ -n "$height" ]; then
    echo "$width|$height|${refresh:-60}|kmsprint"
    return 0
  fi
  return 1
}

detect_via_tvservice() {
  # Legacy detection (older Pi OS)
  if ! command -v tvservice &>/dev/null; then
    return 1
  fi

  local status
  status=$(tvservice -s 2>/dev/null) || return 1

  if echo "$status" | grep -q "TV is off"; then
    return 1
  fi

  local resolution
  resolution=$(echo "$status" | grep -oP '\d+x\d+' | head -1)
  local width height
  width=$(echo "$resolution" | cut -dx -f1)
  height=$(echo "$resolution" | cut -dx -f2)
  local refresh
  refresh=$(echo "$status" | grep -oP '@\s*\K\d+' | head -1)

  if [ -n "$width" ] && [ -n "$height" ]; then
    echo "$width|$height|${refresh:-60}|tvservice"
    return 0
  fi
  return 1
}

detect_via_drm_sysfs() {
  # Direct DRM sysfs read (always available on Linux with KMS)
  local card_path="/sys/class/drm"
  local connector=""

  for conn in "$card_path"/card*-HDMI-*; do
    if [ -f "$conn/status" ] && [ "$(cat "$conn/status")" = "connected" ]; then
      connector="$conn"
      break
    fi
  done

  if [ -z "$connector" ]; then
    # Try any connected output
    for conn in "$card_path"/card*-*/; do
      if [ -f "$conn/status" ] && [ "$(cat "$conn/status")" = "connected" ]; then
        connector="$conn"
        break
      fi
    done
  fi

  if [ -z "$connector" ]; then
    return 1
  fi

  # Read current mode
  local mode_file="$connector/modes"
  if [ -f "$mode_file" ]; then
    local first_mode
    first_mode=$(head -1 "$mode_file")
    local width height
    width=$(echo "$first_mode" | grep -oP '^\d+' || echo "")
    height=$(echo "$first_mode" | grep -oP 'x\K\d+' || echo "")

    if [ -n "$width" ] && [ -n "$height" ]; then
      echo "$width|$height|60|drm-sysfs"
      return 0
    fi
  fi
  return 1
}

# ---------- EDID parsing ----------

parse_edid() {
  local connector_path=""
  local card_path="/sys/class/drm"

  # Find connected HDMI connector
  for conn in "$card_path"/card*-HDMI-*; do
    if [ -f "$conn/status" ] && [ "$(cat "$conn/status")" = "connected" ]; then
      connector_path="$conn"
      break
    fi
  done

  [ -z "$connector_path" ] && return 1

  local edid_file="$connector_path/edid"
  [ ! -f "$edid_file" ] && return 1

  local manufacturer="" model="" serial="" hdr="false" max_width="" max_height=""

  # Try edid-decode if available
  if command -v edid-decode &>/dev/null; then
    local decoded
    decoded=$(edid-decode "$edid_file" 2>/dev/null) || true

    manufacturer=$(echo "$decoded" | grep -i "Manufacturer:" | head -1 | sed 's/.*Manufacturer:\s*//' | tr -d '\n')
    model=$(echo "$decoded" | grep -iP "Monitor name:|Display Product Name:" | head -1 | sed 's/.*:\s*//' | tr -d '\n')
    serial=$(echo "$decoded" | grep -iP "Monitor serial|Display Product Serial" | head -1 | sed 's/.*:\s*//' | tr -d '\n')

    # Check for HDR metadata
    if echo "$decoded" | grep -qi "HDR Static Metadata\|SMPTE ST 2084\|BT.2020"; then
      hdr="true"
    fi

    # Max resolution from EDID
    max_width=$(echo "$decoded" | grep -oP 'Maximum image size:\s*\K\d+' | head -1)
    max_height=$(echo "$decoded" | grep -oP 'Maximum image size:.*x\s*\K\d+' | head -1)
  fi

  # Fallback: parse raw EDID binary for manufacturer
  if [ -z "$manufacturer" ] && [ -f "$edid_file" ]; then
    # Bytes 8-9 contain manufacturer ID (compressed ASCII)
    local mfg_bytes
    mfg_bytes=$(xxd -p -l 2 -s 8 "$edid_file" 2>/dev/null) || true
    if [ -n "$mfg_bytes" ]; then
      local mfg_int=$((16#$mfg_bytes))
      local c1=$(( (mfg_int >> 10) & 0x1F ))
      local c2=$(( (mfg_int >> 5) & 0x1F ))
      local c3=$(( mfg_int & 0x1F ))
      manufacturer=$(printf "\\x$(printf '%02x' $((c1 + 64)))\\x$(printf '%02x' $((c2 + 64)))\\x$(printf '%02x' $((c3 + 64)))")
    fi
  fi

  # Read supported modes for max resolution
  local modes_file="$connector_path/modes"
  if [ -f "$modes_file" ] && [ -z "$max_width" ]; then
    local max_mode
    max_mode=$(sort -t'x' -k1 -n -r "$modes_file" 2>/dev/null | head -1)
    max_width=$(echo "$max_mode" | grep -oP '^\d+')
    max_height=$(echo "$max_mode" | grep -oP 'x\K\d+')
  fi

  echo "${manufacturer:-unknown}|${model:-unknown}|${serial:-}|${hdr}|${max_width:-0}|${max_height:-0}"
}

# ---------- get all supported modes ----------

get_supported_modes() {
  local card_path="/sys/class/drm"

  for conn in "$card_path"/card*-HDMI-*; do
    if [ -f "$conn/status" ] && [ "$(cat "$conn/status")" = "connected" ]; then
      if [ -f "$conn/modes" ]; then
        cat "$conn/modes" | sort -u
      fi
      return 0
    fi
  done

  # Fallback: tvservice
  if command -v tvservice &>/dev/null; then
    tvservice -m CEA 2>/dev/null | grep -oP '\d+x\d+' | sort -u
    tvservice -m DMT 2>/dev/null | grep -oP '\d+x\d+' | sort -u
  fi
}

# ---------- check 4K capability ----------

is_4k_capable() {
  local modes
  modes=$(get_supported_modes 2>/dev/null)

  if echo "$modes" | grep -qP "3840|4096"; then
    echo "true"
  else
    echo "false"
  fi
}

# ---------- main output ----------

ACTION="${1:-detect}"

case "$ACTION" in
  detect)
    # Get current resolution
    local_info=""
    local_info=$(detect_via_kmsprint 2>/dev/null) || \
    local_info=$(detect_via_drm_sysfs 2>/dev/null) || \
    local_info=$(detect_via_tvservice 2>/dev/null) || \
    local_info="0|0|60|none"

    IFS='|' read -r width height refresh method <<< "$local_info"

    # Get EDID info
    edid_info=""
    edid_info=$(parse_edid 2>/dev/null) || edid_info="unknown|unknown||false|0|0"
    IFS='|' read -r manufacturer model serial hdr max_w max_h <<< "$edid_info"

    # 4K capable?
    can_4k=$(is_4k_capable 2>/dev/null)

    # Orientation detection
    local orientation="landscape"
    local aspect_ratio="16:9"
    if [ "$width" -gt 0 ] 2>/dev/null && [ "$height" -gt 0 ] 2>/dev/null; then
      if [ "$height" -gt "$width" ]; then
        orientation="portrait"
      fi
      # Calculate aspect ratio (common ones)
      local ratio_val
      ratio_val=$(awk "BEGIN {printf \"%.2f\", $width/$height}")
      case "$ratio_val" in
        1.77|1.78) aspect_ratio="16:9" ;;
        1.33)      aspect_ratio="4:3" ;;
        1.60)      aspect_ratio="16:10" ;;
        2.37|2.38|2.39) aspect_ratio="21:9" ;;
        0.56)      aspect_ratio="9:16" ;;
        0.75)      aspect_ratio="3:4" ;;
        *)         aspect_ratio="${ratio_val}:1" ;;
      esac
    fi

    # Build JSON
    cat > "$DISPLAY_CACHE" << ENDJSON
{
  "current_resolution": "${width}x${height}",
  "width": $width,
  "height": $height,
  "refresh_rate": $refresh,
  "orientation": "$orientation",
  "aspect_ratio": "$aspect_ratio",
  "detection_method": "$method",
  "manufacturer": "$manufacturer",
  "model": "$model",
  "serial": "$serial",
  "hdr_capable": $hdr,
  "max_resolution": "${max_w}x${max_h}",
  "is_4k_capable": $can_4k,
  "is_4k_active": $([ "$width" -ge 3840 ] 2>/dev/null && echo true || echo false),
  "detected_at": "$(date -Iseconds)"
}
ENDJSON

    cat "$DISPLAY_CACHE"
    ;;

  resolution)
    # Quick: just output WIDTHxHEIGHT
    local_info=$(detect_via_kmsprint 2>/dev/null) || \
    local_info=$(detect_via_drm_sysfs 2>/dev/null) || \
    local_info=$(detect_via_tvservice 2>/dev/null) || \
    local_info="1920|1080|60|fallback"

    IFS='|' read -r w h _ _ <<< "$local_info"
    echo "${w}x${h}"
    ;;

  modes)
    get_supported_modes
    ;;

  cached)
    if [ -f "$DISPLAY_CACHE" ]; then
      cat "$DISPLAY_CACHE"
    else
      echo "{}"
    fi
    ;;

  *)
    echo "Usage: $0 {detect|resolution|modes|cached}"
    exit 1
    ;;
esac
