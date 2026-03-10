#!/bin/bash
# =============================================================================
# Cutegory PiCast Client — Main daemon loop
# Polls backoffice sync API, manages media download + mpv playback + CEC
# =============================================================================

set -euo pipefail

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

echo "[picast] Starting Cutegory PiCast client"
echo "[picast] Server: $SERVER_URL"
echo "[picast] Device: $DEVICE_ID"
echo "[picast] Poll interval: ${POLL_INTERVAL:-30}s"

POLL_INTERVAL="${POLL_INTERVAL:-30}"
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
  local pid_file="$SCRIPT_DIR/.mpv.pid"
  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "playing"
  else
    echo "idle"
  fi
}

# ---------- command queue ----------

run_cec_test() {
  local cmd_id="$1"
  if ! command -v cec-client &>/dev/null; then
    echo "{\"id\":\"$cmd_id\",\"status\":\"error\",\"result\":{\"error\":\"cec-client not installed\"}}"
    return
  fi

  local output
  output=$(echo "pow 0" | timeout 10 cec-client -s -d 1 2>/dev/null) || true
  local power
  power=$(echo "$output" | grep -oP 'power status: \K\w+' || echo "")

  if [ -n "$power" ]; then
    echo "{\"id\":\"$cmd_id\",\"status\":\"done\",\"result\":{\"cec_supported\":true,\"tv_power\":\"$power\"}}"
  else
    echo "{\"id\":\"$cmd_id\",\"status\":\"done\",\"result\":{\"cec_supported\":false,\"tv_power\":\"unknown\"}}"
  fi
}

run_cec_action() {
  local cmd_id="$1"
  local action="$2"
  if ! command -v cec-client &>/dev/null; then
    echo "{\"id\":\"$cmd_id\",\"status\":\"error\",\"result\":{\"error\":\"cec-client not installed\"}}"
    return
  fi

  echo "$action" | timeout 10 cec-client -s -d 1 2>/dev/null || true
  echo "{\"id\":\"$cmd_id\",\"status\":\"done\",\"result\":{\"success\":true}}"
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
      reboot)
        # Send result BEFORE rebooting
        result="{\"id\":\"$cmd_id\",\"status\":\"done\",\"result\":{\"success\":true}}"
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
  local uptime
  uptime=$(get_uptime_sec)

  # Read display info from cache
  local display_res="unknown" display_model="unknown" display_4k="false" display_hdr="false" display_orientation="landscape" display_aspect="16:9"
  local display_cache="$SCRIPT_DIR/.display-info.json"
  if [ -f "$display_cache" ]; then
    display_res=$(jq -r '.current_resolution // "unknown"' "$display_cache")
    display_model=$(jq -r '(.manufacturer // "") + " " + (.model // "") | gsub("^ | $"; "")' "$display_cache")
    display_4k=$(jq -r '.is_4k_active // false' "$display_cache")
    display_hdr=$(jq -r '.hdr_capable // false' "$display_cache")
    display_orientation=$(jq -r '.orientation // "landscape"' "$display_cache")
    display_aspect=$(jq -r '.aspect_ratio // "16:9"' "$display_cache")
  fi

  # CPU temperature (Pi thermal zone)
  local cpu_temp="0"
  if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    cpu_temp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
  fi

  # Include command results if any
  local cmd_results="${PENDING_COMMAND_RESULTS:-[]}"

  curl -sf -X POST "${SERVER_URL}/api/v1/signage/heartbeat" \
    -H "X-Device-Token: ${DEVICE_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"${DEVICE_ID}\",\"ip_address\":\"${ip}\",\"free_disk_mb\":${disk},\"uptime_sec\":${uptime},\"player_status\":\"${status}\",\"display_resolution\":\"${display_res}\",\"display_model\":\"${display_model}\",\"display_4k\":${display_4k},\"display_hdr\":${display_hdr},\"display_orientation\":\"${display_orientation}\",\"display_aspect_ratio\":\"${display_aspect}\",\"cpu_temp\":${cpu_temp},\"command_results\":${cmd_results}}" \
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
  now_minutes=$(( $(date +%H) * 60 + $(date +%M) ))
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

# ---------- cleanup on exit ----------

cleanup() {
  echo "[picast] Shutting down..."
  "$SCRIPT_DIR/player.sh" stop 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# ---------- main loop ----------

while true; do
  # Fetch sync config
  SYNC=$(curl -sf "${SERVER_URL}/api/v1/signage/sync/${DEVICE_ID}" \
    -H "X-Device-Token: ${DEVICE_KEY}" 2>/dev/null) || {
    echo "[picast] $(date +%H:%M:%S) Server unreachable, using cached config"
    sleep "$POLL_INTERVAL"
    continue
  }

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
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Check config hash for changes
  NEW_HASH=$(echo "$SYNC" | jq -r '.config_hash // empty')

  if [ -z "$NEW_HASH" ]; then
    echo "[picast] $(date +%H:%M:%S) Invalid sync response"
    sleep "$POLL_INTERVAL"
    continue
  fi

  if [ "$NEW_HASH" != "$LAST_CONFIG_HASH" ]; then
    echo "[picast] $(date +%H:%M:%S) Config changed ($LAST_CONFIG_HASH -> $NEW_HASH)"

    # Save sync data
    echo "$SYNC" > "$SYNC_CACHE"

    # Sync media files
    "$SCRIPT_DIR/sync.sh" "$SYNC"

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
      "$SCRIPT_DIR/player.sh" restart "$(cat "$SYNC_CACHE")"
    fi
  fi

  # Send heartbeat every 2nd poll (~60s)
  HEARTBEAT_COUNTER=$(( HEARTBEAT_COUNTER + 1 ))
  if [ $(( HEARTBEAT_COUNTER % 2 )) -eq 0 ]; then
    send_heartbeat
  fi

  sleep "$POLL_INTERVAL"
done
