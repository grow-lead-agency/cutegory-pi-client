#!/bin/bash
# =============================================================================
# Cutegory PiCast — Self-update via GitHub tarball (public repo)
# Downloads latest release, compares hash, installs if changed
# Runs on boot (systemd timer) + daily at 04:00
# =============================================================================

set -euo pipefail

INSTALL_DIR="/opt/picast"
UPDATE_DIR="/tmp/picast-update"
LOG_FILE="${INSTALL_DIR}/logs/update.log"
HASH_FILE="${INSTALL_DIR}/.update-hash"
CONFIG_FILE="${INSTALL_DIR}/config.env"

# Load config
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=config.env.example
  source "$CONFIG_FILE"
fi

REPO="${GITHUB_REPO:-grow-lead-agency/cutegory-pi-client}"
BRANCH="${GITHUB_BRANCH:-main}"

log() { echo "[update] $(date +%Y-%m-%d\ %H:%M:%S) $*" | tee -a "$LOG_FILE"; }

mkdir -p "$(dirname "$LOG_FILE")"

# Get latest commit SHA (public repo — no token needed)
LATEST_SHA=$(curl -sf \
  "https://api.github.com/repos/${REPO}/commits/${BRANCH}" 2>/dev/null | \
  jq -r '.sha // empty') || { log "Failed to check for updates (offline?)"; exit 0; }

if [ -z "$LATEST_SHA" ]; then
  log "Failed to get latest commit SHA"
  exit 0
fi

# Compare with last installed version
CURRENT_SHA=""
if [ -f "$HASH_FILE" ]; then
  CURRENT_SHA=$(cat "$HASH_FILE")
fi

if [ "$LATEST_SHA" = "$CURRENT_SHA" ]; then
  log "Already up to date (${LATEST_SHA:0:7})"
  exit 0
fi

log "Update available: ${CURRENT_SHA:0:7} -> ${LATEST_SHA:0:7}"

# Download tarball (public repo — no auth needed)
rm -rf "$UPDATE_DIR"
mkdir -p "$UPDATE_DIR"

curl -sfL \
  "https://api.github.com/repos/${REPO}/tarball/${BRANCH}" | \
  tar xz -C "$UPDATE_DIR" --strip-components=1 2>/dev/null || {
    log "Download failed"
    rm -rf "$UPDATE_DIR"
    exit 0
  }

# Verify download has expected files
if [ ! -f "$UPDATE_DIR/picast-client.sh" ]; then
  log "ERROR: Downloaded archive missing picast-client.sh"
  rm -rf "$UPDATE_DIR"
  exit 0
fi

# Copy updated scripts (never touch config.env)
cd "$UPDATE_DIR"
for script in picast-client.sh sync.sh player.sh cec-control.sh display-detect.sh picast-ctl.sh self-update.sh; do
  if [ -f "$script" ]; then
    cp "$script" "$INSTALL_DIR/$script"
    chmod +x "$INSTALL_DIR/$script"
  fi
done

# Copy updated assets
if [ -d "assets" ]; then
  mkdir -p "$INSTALL_DIR/assets"
  cp -r assets/* "$INSTALL_DIR/assets/" 2>/dev/null || true
fi

# Copy updated systemd services
if [ -f "systemd/picast.service" ]; then
  cp "systemd/picast.service" /etc/systemd/system/picast.service
  systemctl daemon-reload
fi

# Auto-install missing dependencies (if deps file changed)
DEPS_FILE="$INSTALL_DIR/.installed-deps-hash"
NEW_DEPS_HASH=$(md5sum "$UPDATE_DIR/install.sh" 2>/dev/null | cut -d' ' -f1 || echo "")
OLD_DEPS_HASH=$(cat "$DEPS_FILE" 2>/dev/null || echo "")
if [ -n "$NEW_DEPS_HASH" ] && [ "$NEW_DEPS_HASH" != "$OLD_DEPS_HASH" ]; then
  log "Checking for new dependencies..."
  for pkg in chromium-browser cage fbgrab; do
    if ! dpkg -l "$pkg" &>/dev/null 2>&1; then
      log "Installing missing dependency: $pkg"
      apt-get install -y -qq "$pkg" 2>/dev/null || log "WARN: Failed to install $pkg"
    fi
  done
  echo "$NEW_DEPS_HASH" > "$DEPS_FILE"
fi

# Fix ownership
chown -R picast:picast "$INSTALL_DIR"

# Save current version
echo "$LATEST_SHA" > "$HASH_FILE"

# Cleanup
rm -rf "$UPDATE_DIR"

log "Updated to ${LATEST_SHA:0:7}, restarting picast..."
systemctl restart picast

log "Update complete"
