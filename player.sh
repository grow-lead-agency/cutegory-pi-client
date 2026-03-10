#!/bin/bash
# =============================================================================
# Cutegory PiCast — mpv player wrapper
# Manages mpv process, generates playlist, handles image duration + web URLs
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${PICAST_CONFIG:-$SCRIPT_DIR/config.env}"
# shellcheck source=config.env.example
source "$CONFIG_FILE"

MEDIA_DIR="${MEDIA_DIR:-/opt/picast/media}"
PLAYLIST_FILE="$SCRIPT_DIR/.current-playlist.txt"
MPV_PID_FILE="$SCRIPT_DIR/.mpv.pid"
MPV_LOG="${LOG_DIR:-/opt/picast/logs}/mpv.log"

ACTION="${1:-}"
SYNC_DATA="${2:-}"

# ---------- stop ----------

stop_mpv() {
  if [ -f "$MPV_PID_FILE" ]; then
    local pid
    pid=$(cat "$MPV_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "[player] Stopping mpv (PID: $pid)"
      kill "$pid" 2>/dev/null || true
      # Wait for graceful shutdown
      for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      # Force kill if still running
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$MPV_PID_FILE"
  fi
}

# ---------- generate playlist ----------

generate_playlist() {
  local sync="$1"
  > "$PLAYLIST_FILE"

  # Check if playlist has items
  local item_count
  item_count=$(echo "$sync" | jq -r '.items | length')
  if [ "$item_count" = "0" ] || [ "$item_count" = "null" ]; then
    echo "[player] No playlist items"
    return
  fi

  # Generate mpv playlist from media items only (web items handled separately)
  echo "$sync" | jq -r '.items[] | select(.item_type == "media") | .url + "|" + (.duration_sec // 10 | tostring)' | \
  while IFS='|' read -r url duration; do
    local filename
    filename=$(basename "$url")
    local local_path="$MEDIA_DIR/$filename"

    if [ -f "$local_path" ]; then
      echo "$local_path" >> "$PLAYLIST_FILE"
    else
      echo "[player] WARN: Missing media file: $filename"
    fi
  done

  local count
  count=$(wc -l < "$PLAYLIST_FILE" | tr -d ' ')
  echo "[player] Generated playlist with $count items"
}

# ---------- start mpv ----------

start_mpv() {
  local sync="$1"

  # Check if playlist file has content — fallback to standby screen
  if [ ! -s "$PLAYLIST_FILE" ]; then
    local standby="$SCRIPT_DIR/assets/standby.jpg"
    if [ -f "$standby" ]; then
      echo "[player] Empty playlist, showing standby screen"
      echo "$standby" > "$PLAYLIST_FILE"
    else
      echo "[player] Empty playlist, no standby image, not starting mpv"
      return
    fi
  fi

  # Get image duration from first image item (or default 10s)
  local image_duration
  image_duration=$(echo "$sync" | jq -r '[.items[] | select(.item_type == "media" and .type == "image") | .duration_sec][0] // 10')

  # Build mpv command
  local mpv_args=(
    --fs
    --loop-playlist=inf
    --no-terminal
    --no-input-default-bindings
    --no-osc
    --no-osd-bar
    --image-display-duration="$image_duration"
    --playlist="$PLAYLIST_FILE"
    --log-file="$MPV_LOG"
    --hwdec=auto
    --gpu-context=drm
  )

  # Try DRM output first (headless, best Pi performance), fallback to GPU
  if [ -e /dev/dri/card0 ]; then
    mpv_args+=(--vo=drm)
  else
    mpv_args+=(--vo=gpu)
  fi

  # Fullscreen setting
  if [ "${FULLSCREEN:-true}" = "true" ]; then
    mpv_args+=(--fs)
  fi

  # Create log directory
  mkdir -p "$(dirname "$MPV_LOG")"

  echo "[player] Starting mpv (image_dur: ${image_duration}s)"
  "${PLAYER_BIN:-mpv}" "${mpv_args[@]}" &
  local pid=$!
  echo "$pid" > "$MPV_PID_FILE"
  echo "[player] mpv started (PID: $pid)"
}

# ---------- actions ----------

case "${ACTION}" in
  restart)
    if [ -z "$SYNC_DATA" ]; then
      echo "[player] ERROR: No sync data for restart"
      exit 1
    fi
    stop_mpv
    generate_playlist "$SYNC_DATA"
    sleep 1
    start_mpv "$SYNC_DATA"
    ;;
  stop)
    stop_mpv
    ;;
  status)
    if [ -f "$MPV_PID_FILE" ] && kill -0 "$(cat "$MPV_PID_FILE")" 2>/dev/null; then
      echo "[player] Running (PID: $(cat "$MPV_PID_FILE"))"
    else
      echo "[player] Not running"
    fi
    ;;
  *)
    echo "Usage: $0 {restart|stop|status} [sync_data_json]"
    exit 1
    ;;
esac
