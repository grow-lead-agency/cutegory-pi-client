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

# Load last known hash
if [ -f "$HASH_FILE" ]; then
  LAST_CONFIG_HASH=$(cat "$HASH_FILE")
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

  curl -sf -X POST "${SERVER_URL}/api/v1/signage/heartbeat" \
    -H "X-Device-Token: ${DEVICE_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"${DEVICE_ID}\",\"ip_address\":\"${ip}\",\"free_disk_mb\":${disk},\"uptime_sec\":${uptime},\"player_status\":\"${status}\"}" \
    > /dev/null 2>&1 || echo "[picast] $(date +%H:%M:%S) Heartbeat failed (non-fatal)"
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
