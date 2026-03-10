#!/bin/bash
# =============================================================================
# Cutegory PiCast — Media sync
# Downloads missing media files from R2, removes stale ones, verifies SHA-256
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${PICAST_CONFIG:-$SCRIPT_DIR/config.env}"
# shellcheck source=config.env.example
source "$CONFIG_FILE"

SYNC_DATA="${1:-}"
MEDIA_DIR="${MEDIA_DIR:-/opt/picast/media}"

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

# Track which files are needed
declare -A needed_files=()

for entry in $ITEMS; do
  url=$(echo "$entry" | cut -d'|' -f1)
  sha=$(echo "$entry" | cut -d'|' -f2)
  filename=$(basename "$url")
  local_path="$MEDIA_DIR/$filename"
  needed_files["$filename"]=1

  # Check if file exists and hash matches
  if [ -f "$local_path" ] && [ -n "$sha" ]; then
    local_sha=$(sha256sum "$local_path" | cut -d' ' -f1)
    if [ "$local_sha" = "$sha" ]; then
      continue
    fi
    echo "[sync] Hash mismatch for $filename, re-downloading"
  elif [ -f "$local_path" ]; then
    # File exists but no hash to verify — keep it
    continue
  fi

  # Download file
  echo "[sync] Downloading: $filename"
  if curl -sf -o "$local_path.tmp" "$url"; then
    mv "$local_path.tmp" "$local_path"
    echo "[sync] Downloaded: $filename ($(du -h "$local_path" | cut -f1))"
  else
    echo "[sync] ERROR: Failed to download $filename"
    rm -f "$local_path.tmp"
  fi
done

# Remove stale files (not in current playlist)
for file in "$MEDIA_DIR"/*; do
  [ -f "$file" ] || continue
  filename=$(basename "$file")
  if [ -z "${needed_files[$filename]+x}" ]; then
    echo "[sync] Removing stale: $filename"
    rm -f "$file"
  fi
done

echo "[sync] Sync complete (${#needed_files[@]} files)"
