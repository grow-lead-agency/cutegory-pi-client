#!/bin/bash
# =============================================================================
# Cutegory PiCast — Hybrid player orchestrator (v4)
# Plays media via mpv + web URLs via Chromium kiosk
# Media-only: mpv DRM (direct, no X11)
# Hybrid: Xorg persistent + mpv X11 + Chromium kiosk (shared display)
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
XORG_PID_FILE="$SCRIPT_DIR/.xorg.pid"
MPV_LOG="${LOG_DIR:-/opt/picast/logs}/mpv.log"
ORCHESTRATOR_PID_FILE="$SCRIPT_DIR/.orchestrator.pid"
CHROMIUM_DATA_DIR="/tmp/picast-chromium-$(id -u)"

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

# ---------- stop helpers ----------

stop_xorg() {
  if [ -f "$XORG_PID_FILE" ]; then
    local pid
    pid=$(cat "$XORG_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "[player] Stopping Xorg (PID: $pid)"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$XORG_PID_FILE"
  fi
  pkill -f "Xorg.*:0" 2>/dev/null || true
  unset DISPLAY 2>/dev/null || true
}

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
  pkill -f "chromium.*--kiosk.*picast" 2>/dev/null || true
  # Clean profile to prevent SingletonLock permission errors on restart
  rm -rf "$CHROMIUM_DATA_DIR" 2>/dev/null || true
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
  stop_xorg
  # Belt-and-suspenders: kill any orphan processes holding DRM
  killall -9 mpv chromium Xorg 2>/dev/null || true
  sleep 1
  rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
}

# ---------- Xorg management ----------

ensure_xorg() {
  # Check if Xorg is already running
  if [ -f "$XORG_PID_FILE" ] && kill -0 "$(cat "$XORG_PID_FILE")" 2>/dev/null; then
    export DISPLAY=:0
    return 0
  fi

  if ! command -v Xorg &>/dev/null; then
    echo "[player] ERROR: Xorg not found. Install: sudo apt-get install xserver-xorg-core"
    return 1
  fi

  echo "[player] Starting Xorg..."
  # Clean stale lock files
  rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
  # Ensure Xorg allows non-seat users (needed for systemd service)
  if [ -f /etc/X11/Xwrapper.config ]; then
    grep -q "allowed_users=anybody" /etc/X11/Xwrapper.config 2>/dev/null || \
      echo "allowed_users=anybody" >> /etc/X11/Xwrapper.config
  fi
  Xorg :0 vt7 -keeptty -noreset -allowMouseOpenFail 2>/tmp/picast-xorg.log &
  local xpid=$!
  echo "$xpid" > "$XORG_PID_FILE"

  # Poll for Xorg readiness (up to 15s)
  local ready=false
  for _i in $(seq 1 15); do
    if DISPLAY=:0 xdpyinfo &>/dev/null; then
      ready=true
      echo "[player] Xorg ready after ${_i}s (PID: $xpid)"
      break
    fi
    sleep 1
  done

  if [ "$ready" = "true" ]; then
    export DISPLAY=:0
    # Hide cursor
    if command -v unclutter &>/dev/null; then
      DISPLAY=:0 unclutter -idle 0 -root &>/dev/null &
    fi
    return 0
  else
    echo "[player] ERROR: Xorg failed to start"
    grep "EE" /tmp/picast-xorg.log 2>/dev/null | tail -5
    kill -9 "$xpid" 2>/dev/null || true
    rm -f "$XORG_PID_FILE"
    return 1
  fi
}

# ---------- build mpv args ----------

build_mpv_args() {
  local sync="$1"
  local use_x11="${2:-false}"

  local image_duration
  image_duration=$(echo "$sync" | jq -r '[.items[] | select(.item_type == "media" and .type == "image") | .duration_sec][0] // 10')

  MPV_ARGS=(
    --fs
    --no-terminal
    --no-input-default-bindings
    --no-osc
    --no-osd-bar
    --log-file="$MPV_LOG"
    --really-quiet
    --image-display-duration="$image_duration"
    --hwdec=auto-safe
    --hwdec-codecs=all
  )

  # Video output: DRM (direct) or X11 (shared with Chromium)
  if [ "$use_x11" = "true" ]; then
    # X11 mode — shared display with Chromium
    MPV_ARGS+=(--vo=gpu)
    echo "[player] mpv output: X11 (shared display)"
  else
    # DRM mode — media-only, most efficient
    if [ -e /dev/dri/card0 ] || [ -e /dev/dri/card1 ]; then
      MPV_ARGS+=(--vo=drm --gpu-context=drm)
      if [ "$DISPLAY_WIDTH" -ge 3840 ] 2>/dev/null; then
        MPV_ARGS+=(--drm-mode="${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}")
      fi
    else
      MPV_ARGS+=(--vo=gpu)
    fi
    echo "[player] mpv output: DRM (direct)"
  fi

  # Portrait mode
  if [ "$DISPLAY_ORIENTATION" = "portrait" ]; then
    MPV_ARGS+=(--video-rotate=90)
    echo "[player] Portrait mode: rotating content 90°"
  fi

  MPV_ARGS+=(
    --scale=bilinear --dscale=bilinear
    --video-aspect-override=no --keepaspect=yes
    --background-color="#000000"
    --cache=yes --demuxer-max-bytes=50MiB --demuxer-max-back-bytes=25MiB
    --reset-on-next-file=all
  )

  # 4K/HDR
  if [ "$DISPLAY_4K" = "true" ] && [ "$DISPLAY_WIDTH" -ge 3840 ] 2>/dev/null; then
    MPV_ARGS+=(--video-output-levels=full)
  fi
  if [ "$DISPLAY_HDR" = "true" ]; then
    MPV_ARGS+=(--target-colorspace-hint=yes --hdr-compute-peak=yes)
  fi

  # Audio
  local audio_enabled
  audio_enabled=$(echo "$sync" | jq -r '.settings.audio_enabled // false')
  if [ "$audio_enabled" = "false" ]; then
    MPV_ARGS+=(--no-audio)
  else
    MPV_ARGS+=(--ao=alsa --audio-display=no)
  fi
}

# ---------- chromium kiosk ----------

start_chromium_kiosk() {
  local url="$1"
  local duration="$2"

  echo "[player] Chromium kiosk: $url (${duration}s)"

  local chromium_bin=""
  for bin in chromium chromium-browser google-chrome; do
    if command -v "$bin" &>/dev/null; then
      chromium_bin="$bin"
      break
    fi
  done

  if [ -z "$chromium_bin" ]; then
    echo "[player] ERROR: No Chromium browser found, skipping web item"
    sleep "$duration"
    return
  fi

  # Xorg should already be running (started in hybrid mode init)
  if [ -z "${DISPLAY:-}" ]; then
    echo "[player] ERROR: No DISPLAY set, cannot start Chromium"
    sleep "$duration"
    return
  fi

  # Clear Chromium crashed state (prevents "restore pages" dialog)
  local chromium_prefs="$CHROMIUM_DATA_DIR/Default/Preferences"
  if [ -f "$chromium_prefs" ]; then
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$chromium_prefs" 2>/dev/null
    sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$chromium_prefs" 2>/dev/null
  fi

  # Disable screensaver/DPMS
  DISPLAY=:0 xset s noblank 2>/dev/null || true
  DISPLAY=:0 xset s off 2>/dev/null || true
  DISPLAY=:0 xset -dpms 2>/dev/null || true

  # Override Debian default CHROMIUM_FLAGS (extensions, accessibility etc.)
  export CHROMIUM_FLAGS=""

  # dbus-run-session is CRITICAL — without it Chromium exits after ~10s
  DISPLAY=:0 dbus-run-session "$chromium_bin" \
    --kiosk \
    --no-first-run --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-features=TranslateUI,Translate \
    --disable-translate \
    --noerrdialogs --disable-pinch --overscroll-history-navigation=0 \
    --hide-scrollbars --autoplay-policy=no-user-gesture-required \
    --disable-dev-shm-usage --no-sandbox \
    --disable-extensions --disable-background-networking \
    --disable-sync --disable-default-apps --disable-component-update \
    --in-process-gpu --disable-gpu-compositing \
    --user-data-dir="$CHROMIUM_DATA_DIR" \
    "$url" &>/dev/null &
  echo "$!" > "$CHROMIUM_PID_FILE"
  echo "[player] Chromium started (PID: $(cat "$CHROMIUM_PID_FILE"))"
  sleep 3

  # Wait for duration
  sleep "$duration"

  # Stop chromium (Xorg stays running)
  stop_chromium
}

# ---------- play mpv segment (X11 mode) ----------

play_mpv_segment() {
  local playlist_file="$1"
  local total_duration="$2"

  if [ ! -s "$playlist_file" ]; then
    return
  fi

  local count
  count=$(wc -l < "$playlist_file" | tr -d ' ')
  echo "[player] mpv segment: $count files, ${total_duration}s"

  DISPLAY=:0 "${PLAYER_BIN:-mpv}" "${MPV_ARGS[@]}" --playlist="$playlist_file" --loop-playlist=inf &
  local pid=$!
  echo "$pid" > "$MPV_PID_FILE"

  sleep "$total_duration"
  stop_mpv
  sleep 0.5
}

# ---------- parse segments ----------

parse_segments() {
  local sync="$1"
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

# ---------- orchestrator ----------

run_orchestrator() {
  local sync="$1"

  local segments
  segments=$(parse_segments "$sync")
  local segment_count
  segment_count=$(echo "$segments" | jq 'length')

  if [ "$segment_count" = "0" ] || [ "$segment_count" = "null" ]; then
    echo "[player] No items to play, showing standby"
    local standby="$SCRIPT_DIR/assets/standby.jpg"
    if [ -f "$standby" ]; then
      echo "$standby" > "$PLAYLIST_FILE"
      "${PLAYER_BIN:-mpv}" "${MPV_ARGS[@]}" --playlist="$PLAYLIST_FILE" --loop-playlist=inf &
      echo "$!" > "$MPV_PID_FILE"
    fi
    return
  fi

  local has_web
  has_web=$(echo "$segments" | jq '[.[] | select(.type == "web")] | length > 0')

  echo "[player] Playlist: $segment_count segment(s), has_web=$has_web"

  # ---- MEDIA-ONLY: use mpv DRM loop (most efficient, no Xorg) ----
  if [ "$has_web" = "false" ]; then
    echo "[player] Media-only playlist, using mpv DRM loop"
    generate_media_playlist "$sync"
    if [ -s "$PLAYLIST_FILE" ]; then
      "${PLAYER_BIN:-mpv}" "${MPV_ARGS[@]}" --playlist="$PLAYLIST_FILE" --loop-playlist=inf &
      echo "$!" > "$MPV_PID_FILE"
      echo "[player] mpv started (PID: $(cat "$MPV_PID_FILE"))"
    fi
    return
  fi

  # ---- HYBRID: start Xorg ONCE, mpv + Chromium share X11 display ----
  echo "[player] Hybrid playlist — starting Xorg for shared display"
  if ! ensure_xorg; then
    echo "[player] FATAL: Cannot start Xorg, falling back to media-only"
    generate_media_playlist "$sync"
    if [ -s "$PLAYLIST_FILE" ]; then
      "${PLAYER_BIN:-mpv}" "${MPV_ARGS[@]}" --playlist="$PLAYLIST_FILE" --loop-playlist=inf &
      echo "$!" > "$MPV_PID_FILE"
    fi
    return
  fi

  echo "[player] Hybrid orchestrator starting (Xorg on :0)"

  (
    while true; do
      _i=0
      while [ "$_i" -lt "$segment_count" ]; do
        _segment=$(echo "$segments" | jq -c ".[$_i]")
        _seg_type=$(echo "$_segment" | jq -r '.type')
        _seg_duration=$(echo "$_segment" | jq -r '.total_duration')

        if [ "$_seg_type" = "media" ]; then
          _seg_playlist="/tmp/picast-segment-${_i}.txt"
          > "$_seg_playlist"

          echo "$_segment" | jq -r '.items[] | .url' | while read -r url; do
            _filename=$(basename "$url")
            _local_path="$MEDIA_DIR/$_filename"
            if [ -f "$_local_path" ]; then
              _fsize=$(stat -c%s "$_local_path" 2>/dev/null || echo 0)
              if [ "$_fsize" -ge 1024 ]; then
                echo "$_local_path" >> "$_seg_playlist"
              fi
            fi
          done

          play_mpv_segment "$_seg_playlist" "$_seg_duration"
          rm -f "$_seg_playlist"

        elif [ "$_seg_type" = "web" ]; then
          echo "$_segment" | jq -c '.items[]' | while read -r _web_item; do
            _web_url=$(echo "$_web_item" | jq -r '.web_url // empty')
            _web_duration=$(echo "$_web_item" | jq -r '.duration_sec // 30')
            if [ -n "$_web_url" ]; then
              start_chromium_kiosk "$_web_url" "$_web_duration"
            fi
          done
        fi

        _i=$((_i + 1))
      done

      echo "[player] Orchestrator: loop complete, restarting playlist"
    done
  ) &
  disown

  echo "$!" > "$ORCHESTRATOR_PID_FILE"
  echo "[player] Orchestrator started (PID: $(cat "$ORCHESTRATOR_PID_FILE"))"
}

# ---------- generate media-only playlist ----------

generate_media_playlist() {
  local sync="$1"
  > "$PLAYLIST_FILE"

  echo "$sync" | jq -r '.items[] | select(.item_type == "media") | .url' | \
  while read -r url; do
    local filename
    filename=$(basename "$url")
    local local_path="$MEDIA_DIR/$filename"
    if [ -f "$local_path" ]; then
      local fsize
      fsize=$(stat -c%s "$local_path" 2>/dev/null || echo 0)
      if [ "$fsize" -ge 1024 ]; then
        echo "$local_path" >> "$PLAYLIST_FILE"
      fi
    fi
  done

  local count
  count=$(wc -l < "$PLAYLIST_FILE" | tr -d ' ')
  echo "[player] Generated playlist with $count items"
}

# ---------- start ----------

start_player() {
  local sync="$1"

  detect_display

  # Check if hybrid — if so, build X11 mpv args; otherwise DRM
  local has_web
  has_web=$(echo "$sync" | jq '[(.items // [])[] | select(.item_type == "web")] | length > 0')
  build_mpv_args "$sync" "$has_web"

  mkdir -p "$(dirname "$MPV_LOG")"
  if [ -f "$MPV_LOG" ] && [ "$(stat -c%s "$MPV_LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv "$MPV_LOG" "$MPV_LOG.old"
    echo "[player] Log rotated (>10MB)"
  fi

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
    if [ -f "$XORG_PID_FILE" ] && kill -0 "$(cat "$XORG_PID_FILE")" 2>/dev/null; then
      echo "[player] Xorg running (PID: $(cat "$XORG_PID_FILE"))"
    fi
    if [ -f "$MPV_PID_FILE" ] && kill -0 "$(cat "$MPV_PID_FILE")" 2>/dev/null; then
      echo "[player] mpv running (PID: $(cat "$MPV_PID_FILE"))"
      if [ -f "$SCRIPT_DIR/.display-info.json" ]; then
        local display_info
        display_info=$(cat "$SCRIPT_DIR/.display-info.json")
        echo "[player] Display: $(echo "$display_info" | jq -r '.current_resolution') @ $(echo "$display_info" | jq -r '.refresh_rate')Hz"
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
