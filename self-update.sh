#!/bin/bash
# =============================================================================
# Cutegory PiCast — Self-update from GitHub
# Pulls latest scripts, reinstalls if changed, restarts service
# Runs on boot (systemd) + daily cron
# =============================================================================

set -euo pipefail

REPO_URL="https://github.com/grow-lead-agency/cutegory-pi-client.git"
REPO_DIR="/opt/picast/repo"
INSTALL_DIR="/opt/picast"
LOG_FILE="${INSTALL_DIR}/logs/update.log"

log() { echo "[update] $(date +%Y-%m-%d\ %H:%M:%S) $*" | tee -a "$LOG_FILE"; }

mkdir -p "$(dirname "$LOG_FILE")"

# Clone or pull
if [ -d "$REPO_DIR/.git" ]; then
  cd "$REPO_DIR"
  OLD_HEAD=$(git rev-parse HEAD)
  git fetch --quiet origin main 2>/dev/null || { log "Fetch failed (offline?)"; exit 0; }
  git reset --hard origin/main --quiet
  NEW_HEAD=$(git rev-parse HEAD)

  if [ "$OLD_HEAD" = "$NEW_HEAD" ]; then
    log "Already up to date ($OLD_HEAD)"
    exit 0
  fi
  log "Updated: $OLD_HEAD -> $NEW_HEAD"
else
  log "Cloning repository..."
  git clone --depth 1 --branch main "$REPO_URL" "$REPO_DIR" 2>/dev/null || { log "Clone failed (offline?)"; exit 0; }
  log "Clone complete"
fi

# Copy updated scripts (never touch config.env)
cd "$REPO_DIR"
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

# Copy updated systemd service
if [ -f "systemd/picast.service" ]; then
  cp "systemd/picast.service" /etc/systemd/system/picast.service
  systemctl daemon-reload
fi

# Fix ownership
chown -R picast:picast "$INSTALL_DIR"

log "Files updated, restarting picast..."
systemctl restart picast

log "Update complete"
