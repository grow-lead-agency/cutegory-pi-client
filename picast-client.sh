#!/bin/bash
# =============================================================================
# Cutegory PiCast Client — Main daemon loop
# Polls backoffice sync API, manages media download + mpv playback + CEC
# =============================================================================

set -euo pipefail

PICAST_VERSION="1.2.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${PICAST_CONFIG:-$SCRIPT_DIR/config.env}"
SYNC_CACHE="$SCRIPT_DIR/.last-sync.json"
HASH_FILE="$SCRIPT_DIR/.last-hash"
HEARTBEAT_COUNTER=0

# Load config
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[picast] ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi
# shellcheck source=config.env.example
source "$CONFIG_FILE"

# Validate required config
for var in DEVICE_ID DEVICE_KEY SERVER_URL; do
  if [ -z "${!var:-}" ]; then
    echo "[picast] ERROR: $var not set in $CONFIG_FILE"
    exit 1
  fi
done

echo "[picast] Starting Cutegory PiCast client v${PICAST_VERSION}"
echo "[picast] Server: $SERVER_URL"
echo "[picast] Device: $DEVICE_ID"
echo "[picast] Poll interval: ${POLL_INTERVAL:-30}s"

POLL_INTERVAL="${POLL_INTERVAL:-30}"
CURRENT_POLL_INTERVAL="$POLL_INTERVAL"
CONSECUTIVE_FAILURES=0
MAX_BACKOFF=300  # 5 min max backoff
LAST_CONFIG_HASH=""
PENDING_COMMAND_RESULTS="[]"

# Load last known hash
if [ -f "$HASH_FILE" ]; then
  LAST_CONFIG_HASH=$(cat "$HASH_FILE")
fi

# Detect connected display on startup
echo "[picast] Detecting display..."
"$SCRIPT_DIR/display-detect.sh" detect > /dev/null 2>&1 || echo "[picast] Display detection failed (non-fatal)"
if [ -f "$SCRIPT_DIR/.display-info.json" ]; then
  echo "[picast] Display: $(jq -r '.current_resolution' "$SCRIPT_DIR/.display-info.json") ($(jq -r '.model' "$SCRIPT_DIR/.display-info.json"))"
fi

# ---------- helpers ----------

get_local_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || echo ""
}

get_free_disk_mb() {
  df -m "${MEDIA_DIR:-/opt/picast/media}" 2>/dev/null | awk 'NR==2{print $4}' || echo "0"
}

get_uptime_sec() {
  awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null || echo "0"
}

get_player_status() {
  # Check orchestrator (hybrid mode), mpv, or chromium
  local orch_file="$SCRIPT_DIR/.orchestrator.pid"
  local mpv_file="$SCRIPT_DIR/.mpv.pid"
  local chr_file="$SCRIPT_DIR/.chromium.pid"

  if [ -f "$orch_file" ] && kill -0 "$(cat "$orch_file")" 2>/dev/null; then
    echo "playing"
  elif [ -f "$mpv_file" ] && kill -0 "$(cat "$mpv_file")" 2>/dev/null; then
    echo "playing"
  elif [ -f "$chr_file" ] && kill -0 "$(cat "$chr_file")" 2>/dev/null; then
    echo "playing"
  else
    echo "idle"
  fi
}

# ---------- command queue ----------

run_cec_test() {
  local cmd_id="$1"
  if ! command -v cec-client &>/dev/null; then
    jq -n --arg id "$cmd_id" '{id: $id, status: "error", result: {error: "cec-client not installed"}}'
    return
  fi

  local output
  output=$(echo "pow 0" | timeout 10 cec-client -s -d 1 2>/dev/null) || true
  local power
  power=$(echo "$output" | grep -oP 'power status: \K\w+' || echo "")

  if [ -n "$power" ]; then
    jq -n --arg id "$cmd_id" --arg power "$power" \
      '{id: $id, status: "done", result: {cec_supported: true, tv_power: $power}}'
  else
    jq -n --arg id "$cmd_id" \
      '{id: $id, status: "done", result: {cec_supported: false, tv_power: "unknown"}}'
  fi
}

run_screenshot() {
  local cmd_id="$1"
  local screenshot_path="/opt/picast/.screenshot.jpg"
  local mpv_socket="/opt/picast/.mpv-socket"

  if [ -f "$SCRIPT_DIR/.mpv.pid" ] && kill -0 "$(cat "$SCRIPT_DIR/.mpv.pid")" 2>/dev/null; then
    # Method 1: mpv IPC socket (if available)
    if [ -S "$mpv_socket" ]; then
      echo '{"command": ["screenshot-to-file", "'"$screenshot_path"'", "subtitles"]}' | \
        socat - UNIX-CONNECT:"$mpv_socket" >/dev/null 2>&1 || true
      sleep 1
    fi

    # Method 2: framebuffer capture (DRM mode — fb0 exists on Pi 4)
    if [ ! -f "$screenshot_path" ] || [ ! -s "$screenshot_path" ]; then
      if [ -e /dev/fb0 ]; then
        local fb_size
        fb_size=$(tr ',' 'x' < /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo "1920x1080")
        ffmpeg -f rawvideo -pix_fmt bgra -s "$fb_size" -i /dev/fb0 -frames:v 1 -q:v 5 "$screenshot_path" -y 2>/dev/null || true
      fi
    fi

    # Method 3: scrot/import Xorg screenshot fallback (hybrid mode only)
    if [ ! -f "$screenshot_path" ] || [ ! -s "$screenshot_path" ]; then
      if [ -n "${DISPLAY:-}" ]; then
        if command -v scrot &>/dev/null; then
          DISPLAY=:0 scrot -q 85 "$screenshot_path" 2>/dev/null || true
        elif command -v import &>/dev/null; then
          DISPLAY=:0 import -window root "$screenshot_path" 2>/dev/null || true
        fi
      fi
    fi

    if [ -f "$screenshot_path" ] && [ -s "$screenshot_path" ]; then
      # Upload screenshot via dedicated endpoint with multipart form
      local ts
      ts=$(date +%Y%m%d-%H%M%S)
      local upload_result
      upload_result=$(curl -sf -X POST "${SERVER_URL}/api/v1/signage/screenshot" \
        -H "X-Device-Token: ${DEVICE_KEY}" \
        -F "device_id=${DEVICE_ID}" \
        -F "filename=${ts}.jpg" \
        -F "file=@${screenshot_path}" 2>/dev/null) || true

      local r2_path r2_url
      r2_path=$(echo "$upload_result" | jq -r '.path // empty' 2>/dev/null)
      r2_url=$(echo "$upload_result" | jq -r '.url // empty' 2>/dev/null)

      if [ -n "$r2_url" ]; then
        jq -n --arg id "$cmd_id" --arg path "$r2_path" --arg url "$r2_url" \
          '{id: $id, status: "done", result: {success: true, path: $path, url: $url}}'
      elif [ -n "$r2_path" ]; then
        jq -n --arg id "$cmd_id" --arg path "$r2_path" \
          '{id: $id, status: "done", result: {success: true, path: $path}}'
      else
        jq -n --arg id "$cmd_id" \
          '{id: $id, status: "done", result: {success: true, path: "upload_pending"}}'
      fi
    else
      jq -n --arg id "$cmd_id" \
        '{id: $id, status: "error", result: {error: "screenshot capture failed"}}'
    fi
    rm -f "$screenshot_path"
  else
    jq -n --arg id "$cmd_id" \
      '{id: $id, status: "error", result: {error: "player not running"}}'
  fi
}

run_cec_action() {
  local cmd_id="$1"
  local action="$2"

  # Use cec-control.sh which handles CEC + DDC/CI fallback
  local cec_action=""
  case "$action" in
    "on 0")  cec_action="on" ;;
    "standby 0") cec_action="off" ;;
    *) cec_action="status" ;;
  esac

  "$SCRIPT_DIR/cec-control.sh" "$cec_action" 2>/dev/null || true
  jq -n --arg id "$cmd_id" '{id: $id, status: "done", result: {success: true}}'
}

process_commands() {
  local sync_data="$1"
  local cmd_count
  cmd_count=$(echo "$sync_data" | jq -r '.pending_commands | length // 0')

  if [ "$cmd_count" = "0" ] || [ "$cmd_count" = "null" ]; then
    return
  fi

  echo "[picast] $(date +%H:%M:%S) Processing $cmd_count pending command(s)"

  local results="[]"
  local i=0
  while [ "$i" -lt "$cmd_count" ]; do
    local cmd_id cmd_name
    cmd_id=$(echo "$sync_data" | jq -r ".pending_commands[$i].id")
    cmd_name=$(echo "$sync_data" | jq -r ".pending_commands[$i].command")

    echo "[picast] $(date +%H:%M:%S) Command: $cmd_name ($cmd_id)"

    local result=""
    case "$cmd_name" in
      cec_test)
        result=$(run_cec_test "$cmd_id")
        ;;
      cec_on)
        result=$(run_cec_action "$cmd_id" "on 0")
        ;;
      cec_off)
        result=$(run_cec_action "$cmd_id" "standby 0")
        ;;
      screenshot)
        result=$(run_screenshot "$cmd_id")
        ;;
      reboot)
        # Send result BEFORE rebooting
        result=$(jq -n --arg id "$cmd_id" '{id: $id, status: "done", result: {success: true}}')
        PENDING_COMMAND_RESULTS=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
        echo "[picast] $(date +%H:%M:%S) Reboot command — sending result and rebooting"
        send_heartbeat
        sudo reboot
        exit 0
        ;;
      *)
        echo "[picast] $(date +%H:%M:%S) Unknown command: $cmd_name, ignoring"
        i=$((i + 1))
        continue
        ;;
    esac

    if [ -n "$result" ]; then
      results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
      echo "[picast] $(date +%H:%M:%S) Command $cmd_name done"
    fi

    i=$((i + 1))
  done

  PENDING_COMMAND_RESULTS="$results"
}

# ---------- heartbeat ----------

send_heartbeat() {
  local status
  status=$(get_player_status)
  local ip
  ip=$(get_local_ip)
  local disk
  disk=$(get_free_disk_mb)
  local up
  up=$(get_uptime_sec)

  # Read display info from cache (safe via jq)
  local display_cache="$SCRIPT_DIR/.display-info.json"
  local display_json="{}"
  if [ -f "$display_cache" ]; then
    display_json=$(cat "$display_cache")
  fi

  # CPU temperature (Pi thermal zone)
  local cpu_temp="0"
  if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    cpu_temp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
  fi

  # Include command results if any
  local cmd_results="${PENDING_COMMAND_RESULTS:-[]}"

  # Build heartbeat payload safely via jq (no string interpolation bugs)
  local payload
  payload=$(jq -n \
    --arg device_id "$DEVICE_ID" \
    --arg ip "$ip" \
    --argjson disk "${disk:-0}" \
    --argjson uptime "${up:-0}" \
    --arg player_status "$status" \
    --arg version "$PICAST_VERSION" \
    --argjson cpu_temp "${cpu_temp:-0}" \
    --argjson display "$display_json" \
    --argjson cmd_results "$cmd_results" \
    '{
      device_id: $device_id,
      ip_address: $ip,
      free_disk_mb: $disk,
      uptime_sec: $uptime,
      player_status: $player_status,
      client_version: $version,
      cpu_temp: $cpu_temp,
      display_resolution: ($display.current_resolution // "unknown"),
      display_model: (($display.manufacturer // "") + " " + ($display.model // "") | gsub("^ | $"; "")),
      display_4k: ($display.is_4k_active // false),
      display_hdr: ($display.hdr_capable // false),
      display_orientation: ($display.orientation // "landscape"),
      display_aspect_ratio: ($display.aspect_ratio // "16:9"),
      command_results: $cmd_results
    }')

  curl -sf -X POST "${SERVER_URL}/api/v1/signage/heartbeat" \
    -H "X-Device-Token: ${DEVICE_KEY}" \
    -H "X-PiCast-Version: ${PICAST_VERSION}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    > /dev/null 2>&1 || echo "[picast] $(date +%H:%M:%S) Heartbeat failed (non-fatal)"

  # Clear command results after sending
  PENDING_COMMAND_RESULTS="[]"
}

# ---------- working hours (CEC TV on/off) ----------

check_working_hours() {
  local sync_data="$1"
  local tv_off tv_on now_minutes off_minutes on_minutes

  tv_off=$(echo "$sync_data" | jq -r '.working_hours.tv_off // empty')
  tv_on=$(echo "$sync_data" | jq -r '.working_hours.tv_on // empty')

  if [ -z "$tv_off" ] || [ -z "$tv_on" ]; then
    return 0  # no working hours configured, always on
  fi

  # Convert HH:MM to minutes since midnight
  now_minutes=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  off_minutes=$(( $(echo "$tv_off" | cut -d: -f1 | sed 's/^0//') * 60 + $(echo "$tv_off" | cut -d: -f2 | sed 's/^0//') ))
  on_minutes=$(( $(echo "$tv_on" | cut -d: -f1 | sed 's/^0//') * 60 + $(echo "$tv_on" | cut -d: -f2 | sed 's/^0//') ))

  if [ "$off_minutes" -lt "$on_minutes" ]; then
    # Normal range: off at night, on in morning (e.g. off=02:00, on=07:00)
    if [ "$now_minutes" -ge "$off_minutes" ] && [ "$now_minutes" -lt "$on_minutes" ]; then
      return 1  # outside working hours
    fi
  else
    # Inverted range: off during day (unusual but handled)
    if [ "$now_minutes" -ge "$off_minutes" ] || [ "$now_minutes" -lt "$on_minutes" ]; then
      return 1  # outside working hours
    fi
  fi

  return 0  # within working hours
}

# ---------- update splash ----------

SPLASH_PID_FILE="$SCRIPT_DIR/.splash.pid"

show_splash() {
  local splash_img="$SCRIPT_DIR/assets/updating.jpg"
  [ -f "$splash_img" ] || return 0

  # Stop current player first so DRM is free
  "$SCRIPT_DIR/player.sh" stop 2>/dev/null || true
  sleep 0.5

  # Show splash via mpv DRM (brief, non-blocking)
  "${PLAYER_BIN:-mpv}" --vo=drm --fs --no-terminal --no-audio --really-quiet \
    --image-display-duration=inf "$splash_img" &
  echo "$!" > "$SPLASH_PID_FILE"
  echo "[picast] $(date +%H:%M:%S) Showing update splash"
}

hide_splash() {
  if [ -f "$SPLASH_PID_FILE" ]; then
    local pid
    pid=$(cat "$SPLASH_PID_FILE")
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$SPLASH_PID_FILE"
  fi
}

TV_IS_OFF=false

manage_tv_power() {
  local sync_data="$1"

  if [ "${CEC_ENABLED:-true}" != "true" ]; then
    return
  fi

  if check_working_hours "$sync_data"; then
    # Within working hours — TV should be ON
    if [ "$TV_IS_OFF" = true ]; then
      echo "[picast] $(date +%H:%M:%S) Working hours — turning TV ON"
      "$SCRIPT_DIR/cec-control.sh" on
      TV_IS_OFF=false
      # Restart player after TV comes back
      if [ -f "$SYNC_CACHE" ]; then
        local cached
        cached=$(cat "$SYNC_CACHE")
        "$SCRIPT_DIR/player.sh" restart "$cached"
      fi
    fi
  else
    # Outside working hours — TV should be OFF
    if [ "$TV_IS_OFF" = false ]; then
      echo "[picast] $(date +%H:%M:%S) Outside working hours — turning TV OFF"
      "$SCRIPT_DIR/player.sh" stop
      "$SCRIPT_DIR/cec-control.sh" off
      TV_IS_OFF=true
    fi
  fi
}

# ---------- log rotation ----------

rotate_logs() {
  local log_dir="${LOG_DIR:-/opt/picast/logs}"
  local max_size=10485760  # 10MB

  for logfile in "$log_dir"/*.log; do
    [ -f "$logfile" ] || continue
    local size
    size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    if [ "$size" -gt "$max_size" ]; then
      mv "$logfile" "${logfile}.old"
      echo "[picast] $(date +%H:%M:%S) Rotated log: $(basename "$logfile") ($(( size / 1048576 ))MB)"
    fi
  done

  # Trim journalctl if over 50MB
  if journalctl --disk-usage 2>/dev/null | grep -qP '\d{2,}\.?\d*M|G'; then
    sudo journalctl --vacuum-size=50M 2>/dev/null || true
  fi
}

# ---------- cleanup on exit ----------

cleanup() {
  echo "[picast] Shutting down..."
  hide_splash 2>/dev/null || true
  "$SCRIPT_DIR/player.sh" stop 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# ---------- backoff helpers ----------

reset_backoff() {
  CONSECUTIVE_FAILURES=0
  CURRENT_POLL_INTERVAL="$POLL_INTERVAL"
}

increase_backoff() {
  CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
  # Exponential backoff: 30, 60, 120, 240, 300 (capped)
  CURRENT_POLL_INTERVAL=$(( POLL_INTERVAL * (2 ** (CONSECUTIVE_FAILURES > 4 ? 4 : CONSECUTIVE_FAILURES)) ))
  if [ "$CURRENT_POLL_INTERVAL" -gt "$MAX_BACKOFF" ]; then
    CURRENT_POLL_INTERVAL="$MAX_BACKOFF"
  fi
  echo "[picast] $(date +%H:%M:%S) Backoff: next poll in ${CURRENT_POLL_INTERVAL}s (failure #${CONSECUTIVE_FAILURES})"
}

# ---------- main loop ----------

# Rotate logs on startup
rotate_logs 2>/dev/null || true

while true; do
  # Fetch sync config (with version header for compatibility negotiation)
  SYNC=$(curl -sf "${SERVER_URL}/api/v1/signage/sync/${DEVICE_ID}" \
    -H "X-Device-Token: ${DEVICE_KEY}" \
    -H "X-PiCast-Version: ${PICAST_VERSION}" \
    2>/dev/null) || {
    increase_backoff
    echo "[picast] $(date +%H:%M:%S) Server unreachable, using cached config"
    sleep "$CURRENT_POLL_INTERVAL"
    continue
  }

  # Server reachable — reset backoff
  reset_backoff

  # Process pending commands (high priority — do before anything else)
  process_commands "$SYNC"

  # If commands were processed, send heartbeat immediately with results
  if [ "$PENDING_COMMAND_RESULTS" != "[]" ]; then
    send_heartbeat
  fi

  # Manage TV power based on working hours
  manage_tv_power "$SYNC"

  # Skip media sync if TV is off
  if [ "$TV_IS_OFF" = true ]; then
    sleep "$CURRENT_POLL_INTERVAL"
    continue
  fi

  # Check config hash for changes
  NEW_HASH=$(echo "$SYNC" | jq -r '.config_hash // empty')

  if [ -z "$NEW_HASH" ]; then
    echo "[picast] $(date +%H:%M:%S) Invalid sync response"
    sleep "$CURRENT_POLL_INTERVAL"
    continue
  fi

  if [ "$NEW_HASH" != "$LAST_CONFIG_HASH" ]; then
    echo "[picast] $(date +%H:%M:%S) Config changed ($LAST_CONFIG_HASH -> $NEW_HASH)"

    # Show updating splash while syncing
    show_splash

    # Save sync data
    echo "$SYNC" > "$SYNC_CACHE"

    # Sync media files
    "$SCRIPT_DIR/sync.sh" "$SYNC"

    # Hide splash and start new playlist
    hide_splash

    # Restart player with new playlist
    "$SCRIPT_DIR/player.sh" restart "$SYNC"

    # Save hash
    LAST_CONFIG_HASH="$NEW_HASH"
    echo "$NEW_HASH" > "$HASH_FILE"

    echo "[picast] $(date +%H:%M:%S) Update complete"
  else
    # Config unchanged — but ensure player is running (e.g. after service restart)
    if [ "$(get_player_status)" = "idle" ] && [ -f "$SYNC_CACHE" ]; then
      echo "[picast] $(date +%H:%M:%S) Player not running, restarting from cache"
      # Re-run sync to ensure all media files are present (may have been
      # added after last full sync, or lost during reboot/crash)
      "$SCRIPT_DIR/sync.sh" "$(cat "$SYNC_CACHE")" 2>&1 || true
      "$SCRIPT_DIR/player.sh" restart "$(cat "$SYNC_CACHE")"
    fi
  fi

  # Send heartbeat every 2nd poll (~60s)
  HEARTBEAT_COUNTER=$(( HEARTBEAT_COUNTER + 1 ))
  if [ $(( HEARTBEAT_COUNTER % 2 )) -eq 0 ]; then
    send_heartbeat
  fi

  # Periodic log rotation (every ~30 min = 60 polls)
  if [ $(( HEARTBEAT_COUNTER % 60 )) -eq 0 ]; then
    rotate_logs 2>/dev/null || true
  fi

  sleep "$CURRENT_POLL_INTERVAL"
done
