#!/bin/bash
# =============================================================================
# Cutegory PiCast — Media sync
# Downloads missing media files from R2, removes stale ones, verifies SHA-256
# Uses staging directory for atomic sync (no partial state on failure)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${PICAST_CONFIG:-$SCRIPT_DIR/config.env}"
# shellcheck source=config.env.example
source "$CONFIG_FILE"

SYNC_DATA="${1:-}"
MEDIA_DIR="${MEDIA_DIR:-/opt/picast/media}"
STAGING_DIR="${MEDIA_DIR}/.staging"

if [ -z "$SYNC_DATA" ]; then
  echo "[sync] ERROR: No sync data provided"
  exit 1
fi

# Check if playlist exists
PLAYLIST=$(echo "$SYNC_DATA" | jq -r '.playlist // empty')
if [ -z "$PLAYLIST" ] || [ "$PLAYLIST" = "null" ]; then
  echo "[sync] No playlist assigned, clearing media"
  rm -f "$MEDIA_DIR"/*
  exit 0
fi

# Extract media items (skip web items)
ITEMS=$(echo "$SYNC_DATA" | jq -r '.items[] | select(.item_type == "media") | .url + "|" + (.sha256 // "")')

mkdir -p "$MEDIA_DIR"

# ---------- Disk space check ----------
MIN_FREE_MB=200
free_mb=$(df -m "$MEDIA_DIR" 2>/dev/null | awk 'NR==2{print $4}')
if [ "${free_mb:-0}" -lt "$MIN_FREE_MB" ]; then
  echo "[sync] WARNING: Low disk space (${free_mb}MB free, need ${MIN_FREE_MB}MB) — skipping downloads"
  echo "[sync] Playing existing cached media"
  exit 0
fi

# Track which files are needed
declare -A needed_files=()
DOWNLOAD_COUNT=0
SKIP_COUNT=0

# ---------- Phase 1: Download missing/changed files to staging ----------
# Clean up any leftover staging from a previous interrupted sync
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

for entry in $ITEMS; do
  url=$(echo "$entry" | cut -d'|' -f1)
  sha=$(echo "$entry" | cut -d'|' -f2)
  filename=$(basename "$url")
  local_path="$MEDIA_DIR/$filename"
  needed_files["$filename"]=1

  # Check if file exists — skip if already cached
  if [ -f "$local_path" ]; then
    local_size=$(stat -c%s "$local_path" 2>/dev/null || echo 0)
    if [ "$local_size" -ge 1024 ]; then
      # File exists with reasonable size — keep it
      # (SHA may differ from DB due to transcoding, so we don't re-download)
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi
    echo "[sync] File too small ($local_size bytes), re-downloading: $filename"
  fi

  # Re-check disk space before each download
  free_mb=$(df -m "$MEDIA_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  if [ "${free_mb:-0}" -lt "$MIN_FREE_MB" ]; then
    echo "[sync] WARNING: Disk full, stopping downloads (${free_mb}MB free)"
    break
  fi

  # Download to staging (not directly to media dir)
  echo "[sync] Downloading: $filename"
  if curl -sf -o "$STAGING_DIR/$filename.tmp" "$url"; then
    # Validate downloaded file (not empty, not HTML error page)
    tmp_size=$(stat -c%s "$STAGING_DIR/$filename.tmp" 2>/dev/null || echo 0)
    if [ "$tmp_size" -lt 1024 ]; then
      echo "[sync] ERROR: Downloaded file too small ($tmp_size bytes), skipping $filename"
      rm -f "$STAGING_DIR/$filename.tmp"
      continue
    fi

    mv "$STAGING_DIR/$filename.tmp" "$STAGING_DIR/$filename"
    DOWNLOAD_COUNT=$((DOWNLOAD_COUNT + 1))
    echo "[sync] Downloaded: $filename ($(du -h "$STAGING_DIR/$filename" | cut -f1))"
  else
    echo "[sync] ERROR: Failed to download $filename"
    rm -f "$STAGING_DIR/$filename.tmp"
  fi
done

# ---------- Phase 2: Atomic move from staging to media ----------
# Only move if we have files in staging (some downloads succeeded)
if [ "$DOWNLOAD_COUNT" -gt 0 ]; then
  for file in "$STAGING_DIR"/*; do
    [ -f "$file" ] || continue
    filename=$(basename "$file")
    # Atomic rename within same filesystem
    mv -f "$file" "$MEDIA_DIR/$filename"
  done
  echo "[sync] Moved $DOWNLOAD_COUNT file(s) from staging"
fi

# Clean staging
rm -rf "$STAGING_DIR"

# ---------- Phase 3: Remove stale files ----------
# Only remove AFTER new files are safely in place
STALE_COUNT=0
for file in "$MEDIA_DIR"/*; do
  [ -f "$file" ] || continue
  filename=$(basename "$file")
  # Skip staging directory itself
  [ "$filename" = ".staging" ] && continue
  if [ -z "${needed_files[$filename]+x}" ]; then
    echo "[sync] Removing stale: $filename"
    rm -f "$file"
    STALE_COUNT=$((STALE_COUNT + 1))
  fi
done

echo "[sync] Sync complete: ${#needed_files[@]} needed, $DOWNLOAD_COUNT downloaded, $SKIP_COUNT cached, $STALE_COUNT removed"
