#!/bin/bash
# =============================================================================
# Cutegory PiCast — Hybrid player orchestrator (v3)
# Plays media via mpv + web URLs via Chromium kiosk
# Display-aware, 4K ready, smooth transitions, all-day reliability
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${PICAST_CONFIG:-$SCRIPT_DIR/config.env}"
# shellcheck source=config.env.example
source "$CONFIG_FILE"

MEDIA_DIR="${MEDIA_DIR:-/opt/picast/media}"
PLAYLIST_FILE="$SCRIPT_DIR/.current-playlist.txt"
MPV_PID_FILE="$SCRIPT_DIR/.mpv.pid"
CHROMIUM_PID_FILE="$SCRIPT_DIR/.chromium.pid"
MPV_LOG="${LOG_DIR:-/opt/picast/logs}/mpv.log"
ORCHESTRATOR_PID_FILE="$SCRIPT_DIR/.orchestrator.pid"

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

# ---------- stop all players ----------

stop_chromium() {
  if [ -f "$CHROMIUM_PID_FILE" ]; then
    local pid
    pid=$(cat "$CHROMIUM_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "[player] Stopping Chromium (PID: $pid)"
      kill "$pid" 2>/dev/null || true
      sleep 0.5
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$CHROMIUM_PID_FILE"
  fi
  # Clean up any stray chromium processes from kiosk mode
  pkill -f "chromium.*--kiosk.*picast" 2>/dev/null || true
}

stop_mpv() {
  if [ -f "$MPV_PID_FILE" ]; then
    local pid
    pid=$(cat "$MPV_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "[player] Stopping mpv (PID: $pid)"
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$MPV_PID_FILE"
  fi
}

stop_orchestrator() {
  if [ -f "$ORCHESTRATOR_PID_FILE" ]; then
    local pid
    pid=$(cat "$ORCHESTRATOR_PID_FILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$ORCHESTRATOR_PID_FILE"
  fi
}

stop_all() {
  stop_orchestrator
  stop_chromium
  stop_mpv
}

# ---------- build mpv args ----------

build_mpv_args() {
  local sync="$1"

  # Get image duration from sync data (or default 10s)
  local image_duration
  image_duration=$(echo "$sync" | jq -r '[.items[] | select(.item_type == "media" and .type == "image") | .duration_sec][0] // 10')

  # ---------- Core args ----------
  MPV_ARGS=(
    --fs
    --no-terminal
    --no-input-default-bindings
    --no-osc
    --no-osd-bar
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
    MPV_ARGS+=(
      --vo=drm
      --gpu-context=drm
    )
    if [ "$DISPLAY_WIDTH" -ge 3840 ] 2>/dev/null; then
      MPV_ARGS+=(--drm-mode="${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}")
      echo "[player] DRM mode: ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}"
    fi
  else
    MPV_ARGS+=(--vo=gpu)
  fi

  # ---------- Portrait mode (rotated TV) ----------
  if [ "$DISPLAY_ORIENTATION" = "portrait" ]; then
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
    MPV_ARGS+=(--video-output-levels=full)
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
  else
    MPV_ARGS+=(
      --ao=alsa
      --audio-display=no
    )
  fi
}

# ---------- chromium kiosk ----------

start_chromium_kiosk() {
  local url="$1"
  local duration="$2"

  echo "[player] Chromium kiosk: $url (${duration}s)"

  # Chromium needs DISPLAY or wayland — on headless Pi with DRM, use cage or direct
  # For DRM-only Pi, we use cage (minimal Wayland compositor) if available,
  # otherwise fall back to X with xinit
  local chromium_bin=""
  for bin in chromium chromium-browser google-chrome; do
    if command -v "$bin" &>/dev/null; then
      chromium_bin="$bin"
      break
    fi
  done

  if [ -z "$chromium_bin" ]; then
    echo "[player] ERROR: No Chromium browser found, skipping web item"
    return 1
  fi

  local chromium_args=(
    --kiosk
    --no-first-run
    --disable-infobars
    --disable-session-crashed-bubble
    --disable-features=TranslateUI
    --noerrdialogs
    --disable-pinch
    --overscroll-history-navigation=0
    --hide-scrollbars
    --autoplay-policy=no-user-gesture-required
    --disable-dev-shm-usage
    --disable-gpu-sandbox
    --user-data-dir=/tmp/picast-chromium
    --window-size="${DISPLAY_WIDTH},${DISPLAY_HEIGHT}"
    --app="$url"
  )

  # Check if we have a display server
  if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    # X11 or Wayland available
    "$chromium_bin" "${chromium_args[@]}" &>/dev/null &
    echo "$!" > "$CHROMIUM_PID_FILE"
  elif command -v cage &>/dev/null; then
    # Use cage (minimal Wayland compositor for kiosk)
    cage -- "$chromium_bin" "${chromium_args[@]}" &>/dev/null &
    echo "$!" > "$CHROMIUM_PID_FILE"
  else
    # Fallback: start minimal X server just for Chromium
    if command -v xinit &>/dev/null; then
      xinit "$chromium_bin" "${chromium_args[@]}" -- :1 vt2 &>/dev/null &
      echo "$!" > "$CHROMIUM_PID_FILE"
    else
      echo "[player] ERROR: No display server (X11/Wayland/cage) available for Chromium"
      echo "[player] Install cage: sudo apt-get install cage"
      return 1
    fi
  fi

  # Wait for specified duration
  sleep "$duration"

  # Stop chromium after duration
  stop_chromium
}

# ---------- play mpv segment ----------

play_mpv_segment() {
  local playlist_file="$1"
  local total_duration="$2"

  if [ ! -s "$playlist_file" ]; then
    return
  fi

  local count
  count=$(wc -l < "$playlist_file" | tr -d ' ')
  echo "[player] mpv segment: $count files, ${total_duration}s"

  # For single-pass (not looping), use --loop-playlist=no and let mpv exit naturally
  # For timed playback, we kill after total_duration
  "${PLAYER_BIN:-mpv}" "${MPV_ARGS[@]}" --playlist="$playlist_file" --loop-playlist=inf &
  local pid=$!
  echo "$pid" > "$MPV_PID_FILE"

  # Wait for duration, then stop
  sleep "$total_duration"

  stop_mpv
}

# ---------- parse segments from sync data ----------
# Groups consecutive items of the same type into segments
# Output: JSON array of segments [{type, items: [{...}], total_duration}]

parse_segments() {
  local sync="$1"

  # Use jq to group consecutive items by type
  echo "$sync" | jq -c '
    [.items // [] | to_entries |
      reduce .[] as $e (
        [];
        if length == 0 then
          [{type: $e.value.item_type, items: [$e.value]}]
        elif .[-1].type == $e.value.item_type then
          .[-1].items += [$e.value] | .
        else
          . + [{type: $e.value.item_type, items: [$e.value]}]
        end
      ) |
      .[] |
      {type, items, total_duration: ([.items[].duration_sec] | add)}
    ]
  '
}

# ---------- orchestrator loop ----------

run_orchestrator() {
  local sync="$1"

  # Parse segments
  local segments
  segments=$(parse_segments "$sync")

  local segment_count
  segment_count=$(echo "$segments" | jq 'length')

  if [ "$segment_count" = "0" ] || [ "$segment_count" = "null" ]; then
    echo "[player] No items to play"
    # Show standby
    local standby="$SCRIPT_DIR/assets/standby.jpg"
    if [ -f "$standby" ]; then
      echo "[player] Showing standby screen"
      echo "$standby" > "$PLAYLIST_FILE"
      "${PLAYER_BIN:-mpv}" "${MPV_ARGS[@]}" --playlist="$PLAYLIST_FILE" --loop-playlist=inf &
      echo "$!" > "$MPV_PID_FILE"
    fi
    return
  fi

  local has_web
  has_web=$(echo "$segments" | jq '[.[] | select(.type == "web")] | length > 0')
  local has_media
  has_media=$(echo "$segments" | jq '[.[] | select(.type == "media")] | length > 0')

  echo "[player] Playlist: $segment_count segment(s), web=$has_web, media=$has_media"

  # Simple case: only media items — use mpv loop (original behavior, most efficient)
  if [ "$has_web" = "false" ]; then
    echo "[player] Media-only playlist, using mpv loop"
    generate_media_playlist "$sync"
    if [ -s "$PLAYLIST_FILE" ]; then
      "${PLAYER_BIN:-mpv}" "${MPV_ARGS[@]}" --playlist="$PLAYLIST_FILE" --loop-playlist=inf &
      echo "$!" > "$MPV_PID_FILE"
      echo "[player] mpv started (PID: $(cat "$MPV_PID_FILE"))"
    fi
    return
  fi

  # Hybrid case: mix of media + web — orchestrate segments in a loop
  echo "[player] Hybrid playlist, starting orchestrator loop"

  (
    while true; do
      local i=0
      while [ "$i" -lt "$segment_count" ]; do
        local segment
        segment=$(echo "$segments" | jq -c ".[$i]")
        local seg_type
        seg_type=$(echo "$segment" | jq -r '.type')
        local seg_duration
        seg_duration=$(echo "$segment" | jq -r '.total_duration')

        if [ "$seg_type" = "media" ]; then
          # Build a temporary playlist for this media segment
          local seg_playlist="/tmp/picast-segment-${i}.txt"
          > "$seg_playlist"

          echo "$segment" | jq -r '.items[] | .url' | while read -r url; do
            local filename
            filename=$(basename "$url")
            local local_path="$MEDIA_DIR/$filename"
            if [ -f "$local_path" ]; then
              local fsize
              fsize=$(stat -c%s "$local_path" 2>/dev/null || echo 0)
              if [ "$fsize" -ge 1024 ]; then
                echo "$local_path" >> "$seg_playlist"
              else
                echo "[player] WARN: Skipping corrupt file: $filename ($fsize bytes)"
              fi
            else
              echo "[player] WARN: Missing file: $filename"
            fi
          done

          play_mpv_segment "$seg_playlist" "$seg_duration"
          rm -f "$seg_playlist"

        elif [ "$seg_type" = "web" ]; then
          # Play each web item sequentially
          echo "$segment" | jq -c '.items[]' | while read -r web_item; do
            local web_url
            web_url=$(echo "$web_item" | jq -r '.web_url // empty')
            local web_duration
            web_duration=$(echo "$web_item" | jq -r '.duration_sec // 30')

            if [ -n "$web_url" ]; then
              start_chromium_kiosk "$web_url" "$web_duration"
            fi
          done
        fi

        i=$((i + 1))
      done

      echo "[player] Orchestrator: loop complete, restarting playlist"
    done
  ) &

  echo "$!" > "$ORCHESTRATOR_PID_FILE"
  echo "[player] Orchestrator started (PID: $(cat "$ORCHESTRATOR_PID_FILE"))"
}

# ---------- generate media-only playlist (legacy path) ----------

generate_media_playlist() {
  local sync="$1"
  > "$PLAYLIST_FILE"

  local item_count
  item_count=$(echo "$sync" | jq -r '.items | length')
  if [ "$item_count" = "0" ] || [ "$item_count" = "null" ]; then
    echo "[player] No playlist items"
    return
  fi

  echo "$sync" | jq -r '.items[] | select(.item_type == "media") | .url' | \
  while read -r url; do
    local filename
    filename=$(basename "$url")
    local local_path="$MEDIA_DIR/$filename"

    if [ -f "$local_path" ]; then
      local fsize
      fsize=$(stat -c%s "$local_path" 2>/dev/null || echo 0)
      if [ "$fsize" -lt 1024 ]; then
        echo "[player] WARN: Skipping corrupt/empty file: $filename ($fsize bytes)"
      else
        echo "$local_path" >> "$PLAYLIST_FILE"
      fi
    else
      echo "[player] WARN: Missing media file: $filename"
    fi
  done

  local count
  count=$(wc -l < "$PLAYLIST_FILE" | tr -d ' ')
  echo "[player] Generated playlist with $count items"
}

# ---------- start ----------

start_player() {
  local sync="$1"

  # Detect display capabilities
  detect_display

  # Build mpv args (used by both paths)
  build_mpv_args "$sync"

  # Create log directory
  mkdir -p "$(dirname "$MPV_LOG")"

  # Rotate log if too large (>10MB)
  if [ -f "$MPV_LOG" ] && [ "$(stat -c%s "$MPV_LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv "$MPV_LOG" "$MPV_LOG.old"
    echo "[player] Log rotated (>10MB)"
  fi

  # Run the orchestrator (handles both media-only and hybrid)
  run_orchestrator "$sync"
}

# ---------- actions ----------

case "${ACTION}" in
  restart)
    if [ -z "$SYNC_DATA" ]; then
      echo "[player] ERROR: No sync data for restart"
      exit 1
    fi
    stop_all
    sleep 1
    start_player "$SYNC_DATA"
    ;;
  stop)
    stop_all
    ;;
  status)
    if [ -f "$ORCHESTRATOR_PID_FILE" ] && kill -0 "$(cat "$ORCHESTRATOR_PID_FILE")" 2>/dev/null; then
      echo "[player] Orchestrator running (PID: $(cat "$ORCHESTRATOR_PID_FILE"))"
    fi
    if [ -f "$MPV_PID_FILE" ] && kill -0 "$(cat "$MPV_PID_FILE")" 2>/dev/null; then
      echo "[player] mpv running (PID: $(cat "$MPV_PID_FILE"))"
      if [ -f "$SCRIPT_DIR/.display-info.json" ]; then
        local display_info
        display_info=$(cat "$SCRIPT_DIR/.display-info.json")
        echo "[player] Display: $(echo "$display_info" | jq -r '.current_resolution') @ $(echo "$display_info" | jq -r '.refresh_rate')Hz"
        echo "[player] TV: $(echo "$display_info" | jq -r '.manufacturer') $(echo "$display_info" | jq -r '.model')"
        echo "[player] 4K: $(echo "$display_info" | jq -r 'if .is_4k_active then "active" elif .is_4k_capable then "capable" else "no" end')"
        echo "[player] HDR: $(echo "$display_info" | jq -r 'if .hdr_capable then "yes" else "no" end')"
      fi
    elif [ -f "$CHROMIUM_PID_FILE" ] && kill -0 "$(cat "$CHROMIUM_PID_FILE")" 2>/dev/null; then
      echo "[player] Chromium kiosk running (PID: $(cat "$CHROMIUM_PID_FILE"))"
    else
      echo "[player] Not running"
    fi
    ;;
  display)
    "$SCRIPT_DIR/display-detect.sh" detect
    ;;
  *)
    echo "Usage: $0 {restart|stop|status|display} [sync_data_json]"
    exit 1
    ;;
esac
