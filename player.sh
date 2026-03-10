#!/bin/bash
# =============================================================================
# Cutegory PiCast — mpv player wrapper (v2)
# Display-aware, 4K ready, smooth transitions, all-day reliability
# Manages mpv process, generates playlist, handles image duration + transitions
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${PICAST_CONFIG:-$SCRIPT_DIR/config.env}"
# shellcheck source=config.env.example
source "$CONFIG_FILE"

MEDIA_DIR="${MEDIA_DIR:-/opt/picast/media}"
PLAYLIST_FILE="$SCRIPT_DIR/.current-playlist.txt"
MPV_PID_FILE="$SCRIPT_DIR/.mpv.pid"
MPV_LOG="${LOG_DIR:-/opt/picast/logs}/mpv.log"
WATCHDOG_PID_FILE="$SCRIPT_DIR/.watchdog.pid"

ACTION="${1:-}"
SYNC_DATA="${2:-}"

# ---------- display detection ----------

detect_display() {
  local display_json
  display_json=$("$SCRIPT_DIR/display-detect.sh" detect 2>/dev/null) || display_json="{}"

  DISPLAY_WIDTH=$(echo "$display_json" | jq -r '.width // 1920')
  DISPLAY_HEIGHT=$(echo "$display_json" | jq -r '.height // 1080')
  DISPLAY_REFRESH=$(echo "$display_json" | jq -r '.refresh_rate // 60')
  DISPLAY_HDR=$(echo "$display_json" | jq -r '.hdr_capable // false')
  DISPLAY_4K=$(echo "$display_json" | jq -r '.is_4k_capable // false')
  DISPLAY_MODEL=$(echo "$display_json" | jq -r '.model // "unknown"')
  DISPLAY_ORIENTATION=$(echo "$display_json" | jq -r '.orientation // "landscape"')
  DISPLAY_ASPECT=$(echo "$display_json" | jq -r '.aspect_ratio // "16:9"')

  echo "[player] Display: ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}Hz (${DISPLAY_MODEL})"
  echo "[player] Orientation: ${DISPLAY_ORIENTATION} (${DISPLAY_ASPECT})"
  [ "$DISPLAY_4K" = "true" ] && echo "[player] 4K capable display detected"
  [ "$DISPLAY_HDR" = "true" ] && echo "[player] HDR capable display detected"
}

# ---------- stop ----------

stop_mpv() {
  # Stop watchdog first
  if [ -f "$WATCHDOG_PID_FILE" ]; then
    local wpid
    wpid=$(cat "$WATCHDOG_PID_FILE")
    kill "$wpid" 2>/dev/null || true
    rm -f "$WATCHDOG_PID_FILE"
  fi

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

# ---------- build mpv args ----------

build_mpv_args() {
  local sync="$1"

  # Detect display capabilities
  detect_display

  # Get image duration from sync data (or default 10s)
  local image_duration
  image_duration=$(echo "$sync" | jq -r '[.items[] | select(.item_type == "media" and .type == "image") | .duration_sec][0] // 10')

  # Get transition config from sync data (or defaults)
  local transition_duration
  transition_duration=$(echo "$sync" | jq -r '.settings.transition_duration // 1')

  # ---------- Core args ----------
  MPV_ARGS=(
    --fs
    --loop-playlist=inf
    --no-terminal
    --no-input-default-bindings
    --no-osc
    --no-osd-bar
    --playlist="$PLAYLIST_FILE"
    --log-file="$MPV_LOG"
    --really-quiet
  )

  # ---------- Image display ----------
  MPV_ARGS+=(
    --image-display-duration="$image_duration"
  )

  # ---------- Hardware decoding (Pi 4 V4L2 / VAAPI) ----------
  MPV_ARGS+=(
    --hwdec=auto-safe
    --hwdec-codecs=all
  )

  # ---------- Video output ----------
  if [ -e /dev/dri/card0 ] || [ -e /dev/dri/card1 ]; then
    # DRM output — best for headless Pi signage
    MPV_ARGS+=(
      --vo=drm
      --gpu-context=drm
    )

    # Set DRM mode to match display native resolution
    if [ "$DISPLAY_WIDTH" -ge 3840 ] 2>/dev/null; then
      # 4K active — use native
      MPV_ARGS+=(--drm-mode="${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}")
      echo "[player] DRM mode: ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}"
    fi
  else
    MPV_ARGS+=(--vo=gpu)
  fi

  # ---------- Smooth transitions ----------
  # Note: lavfi fade filters don't work well with --image-display-duration
  # on static images (causes immediate EOF). For now, we rely on mpv's
  # native playlist advancement which is instant but clean (black frame gap ~0ms).
  # True crossfade would require pre-rendering a video from images via ffmpeg.
  echo "[player] Transitions: native (instant cut)"

  # ---------- Portrait mode (rotated TV) ----------
  if [ "$DISPLAY_ORIENTATION" = "portrait" ]; then
    # Rotate content 90° clockwise for portrait-mounted displays
    MPV_ARGS+=(--video-rotate=90)
    echo "[player] Portrait mode: rotating content 90°"
  fi

  # ---------- Scaling for best quality ----------
  MPV_ARGS+=(
    --scale=bilinear
    --dscale=bilinear
    --video-aspect-override=no
    --keepaspect=yes
    --background-color="#000000"
  )

  # ---------- 4K / HDR settings ----------
  if [ "$DISPLAY_4K" = "true" ] && [ "$DISPLAY_WIDTH" -ge 3840 ] 2>/dev/null; then
    MPV_ARGS+=(
      --video-output-levels=full
    )
    echo "[player] 4K output active"
  fi

  if [ "$DISPLAY_HDR" = "true" ]; then
    MPV_ARGS+=(
      --target-colorspace-hint=yes
      --hdr-compute-peak=yes
    )
    echo "[player] HDR passthrough enabled"
  fi

  # ---------- All-day reliability ----------
  MPV_ARGS+=(
    --cache=yes
    --demuxer-max-bytes=50MiB
    --demuxer-max-back-bytes=25MiB
    --reset-on-next-file=all
  )

  # ---------- Audio ----------
  local audio_enabled
  audio_enabled=$(echo "$sync" | jq -r '.settings.audio_enabled // false')
  if [ "$audio_enabled" = "false" ]; then
    MPV_ARGS+=(--no-audio)
    echo "[player] Audio: disabled"
  else
    MPV_ARGS+=(
      --ao=alsa
      --audio-display=no
    )
  fi
}

# ---------- watchdog ----------

start_watchdog() {
  # Background process that monitors mpv and restarts if it crashes
  (
    while true; do
      sleep 30
      if [ -f "$MPV_PID_FILE" ]; then
        local pid
        pid=$(cat "$MPV_PID_FILE" 2>/dev/null) || continue
        if ! kill -0 "$pid" 2>/dev/null; then
          echo "[player] Watchdog: mpv crashed (PID $pid), restarting..."
          # Re-read sync data from cache
          local cache="$SCRIPT_DIR/.last-sync.json"
          if [ -f "$cache" ]; then
            local sync_data
            sync_data=$(cat "$cache")
            build_mpv_args "$sync_data"
            start_mpv_process
          fi
        fi
      fi
    done
  ) &
  echo "$!" > "$WATCHDOG_PID_FILE"
  echo "[player] Watchdog started (PID: $(cat "$WATCHDOG_PID_FILE"))"
}

# ---------- start mpv ----------

start_mpv_process() {
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

  # Create log directory
  mkdir -p "$(dirname "$MPV_LOG")"

  # Rotate log if too large (>10MB)
  if [ -f "$MPV_LOG" ] && [ "$(stat -c%s "$MPV_LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv "$MPV_LOG" "$MPV_LOG.old"
    echo "[player] Log rotated (>10MB)"
  fi

  echo "[player] Starting mpv with ${#MPV_ARGS[@]} args"
  "${PLAYER_BIN:-mpv}" "${MPV_ARGS[@]}" &
  local pid=$!
  echo "$pid" > "$MPV_PID_FILE"
  echo "[player] mpv started (PID: $pid)"
}

start_mpv() {
  local sync="$1"

  build_mpv_args "$sync"
  start_mpv_process
  start_watchdog
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
      # Show display info if cached
      if [ -f "$SCRIPT_DIR/.display-info.json" ]; then
        local display_info
        display_info=$(cat "$SCRIPT_DIR/.display-info.json")
        echo "[player] Display: $(echo "$display_info" | jq -r '.current_resolution') @ $(echo "$display_info" | jq -r '.refresh_rate')Hz"
        echo "[player] TV: $(echo "$display_info" | jq -r '.manufacturer') $(echo "$display_info" | jq -r '.model')"
        echo "[player] 4K: $(echo "$display_info" | jq -r 'if .is_4k_active then "active" elif .is_4k_capable then "capable" else "no" end')"
        echo "[player] HDR: $(echo "$display_info" | jq -r 'if .hdr_capable then "yes" else "no" end')"
      fi
    else
      echo "[player] Not running"
    fi
    ;;
  display)
    # Standalone display detection
    "$SCRIPT_DIR/display-detect.sh" detect
    ;;
  *)
    echo "Usage: $0 {restart|stop|status|display} [sync_data_json]"
    exit 1
    ;;
esac
