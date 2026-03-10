# Cutegory PiCast Client — Claude Instructions

## Projekt

Bash daemon pro Raspberry Pi 4. Přehrává signage obsah (videa, fotky, web stránky) z Cutegory Backoffice.

- **Runtime:** Pi OS Lite 64-bit, bash, mpv, Chromium, curl, jq
- **Jazyk:** Bash (POSIX-compatible kde možné)
- **Verze:** PICAST_VERSION v picast-client.sh

---

## Architektura

```
picast-client.sh    Main daemon (30s poll, exponential backoff)
├── sync.sh         Atomic media sync (staging dir → SHA verify → move)
├── player.sh       Hybrid orchestrator (mpv DRM / Xorg + Chromium)
├── cec-control.sh  Display power (CEC → DDC/CI fallback)
├── display-detect.sh  EDID, kmsprint, DRM sysfs
├── self-update.sh  OTA via GitHub tarball (SHA compare)
└── picast-ctl.sh   Remote management CLI
```

## Pravidla

### Kód
- **Bash only** — žádný Python, Node, nebo jiný runtime
- Shellcheck clean (`shellcheck -e SC2086`)
- Všechny proměnné v double quotes (`"$VAR"`)
- Error handling: `set -euo pipefail` v každém skriptu
- JSON building: vždy `jq -n` (NIKDY string interpolation)
- Logging do stdout/stderr (systemd journal zachytí)
- Config přes `config.env` soubor (ne hardcoded)

### Bezpečnost
- `device_key` NIKDY do gitu — jen v `config.env` (gitignored)
- Žádné root operace kromě install.sh a cron reboot
- mpv/Chromium běží jako neprivilegovaný user `picast`
- PID-based process cleanup (ne `killall`)

### Konvence
- Soubory: `kebab-case.sh`
- Funkce: `snake_case`
- Konstanty: `UPPER_SNAKE_CASE`
- Komentáře: anglicky
- Dokumentace: česky
- API versioning: `X-PiCast-Version` header

### Hardware
- Pi 4 HW decode: H.264 + HEVC only (VP9 = software = choppy)
- CEC: funguje jen na TV (ne monitory)
- DDC/CI: `ddcutil setvcp` pro monitory (Samsung S34CG50 nemá D6 power, jen brightness)
- DRM: `/dev/dri/card0` — mpv `--vo=drm` pro media-only, `--vo=gpu` pro hybrid
