# Cutegory Pi Client — Claude Instructions

## Projekt

Bash daemon pro Raspberry Pi 4, přehrává signage obsah (videa/fotky) z Cutegory Backoffice.
Nahrazuje Yodeck SaaS klienta na Pi.

- **Repo:** `grow-lead-agency/cutegory-pi-client`
- **Backoffice:** `grow-lead-agency/cutegory-backoffice-v2`
- **Runtime:** Raspberry Pi OS Lite (64-bit), bash, mpv, curl, jq, cec-client
- **Jazyk:** Bash (POSIX-compatible kde možné)

---

## Architektura

```
Pi 4 (ARM64)
┌─────────────────────────────────┐
│  picast-client.sh (daemon)      │
│  ├── poll sync API (30s)        │
│  ├── download media z R2        │
│  ├── mpv player (fullscreen)    │
│  └── heartbeat POST             │
│                                 │
│  cec-control.sh                 │
│  └── HDMI CEC TV on/off        │
│                                 │
│  systemd: picast.service        │
└─────────────────────────────────┘
         │                    │
         │ poll/heartbeat     │ download media
         ▼                    ▼
  backoffice.cutegory.cz    signage-media.cutegory.cz
  /api/v1/signage/sync/     (Cloudflare R2, public)
```

---

## Pravidla

### Kód
- **Bash** — žádný Python, Node, nebo jiný runtime
- Shellcheck clean (`shellcheck -e SC2086`)
- Všechny proměnné v double quotes (`"$VAR"`)
- Error handling: `set -euo pipefail` v každém skriptu
- Logging do stdout/stderr (systemd journal zachytí)
- Config přes `config.env` soubor (ne hardcoded)

### Bezpečnost
- `device_key` NIKDY do gitu — jen v `config.env` (gitignored)
- Žádné root operace kromě install.sh
- mpv běží jako neprivilegovaný user `picast`

### Konvence
- Soubory: `kebab-case.sh`
- Funkce: `snake_case`
- Konstanty: `UPPER_SNAKE_CASE`
- Komentáře: anglicky
- Dokumentace: česky

---

## Struktura

```
cutegory-pi-client/
├── CLAUDE.md               # Tento soubor
├── README.md               # Setup guide
├── config.env.example      # Šablona konfigurace
├── install.sh              # One-click install (deps + user + systemd)
├── uninstall.sh            # Cleanup
├── picast-client.sh        # Hlavní daemon loop
├── sync.sh                 # Media sync (download z R2, remove stale)
├── player.sh               # mpv wrapper
├── cec-control.sh          # HDMI CEC TV on/off
├── systemd/
│   └── picast.service      # systemd unit
└── scripts/
    └── generate-device-key.sh
```

---

## API Contract

### Sync endpoint
```
GET https://backoffice.cutegory.cz/api/v1/signage/sync/{deviceId}
Header: X-Device-Token: {device_key}

Response 200:
{
  "config_hash": "a1b2c3d4",
  "playlist": { "id": "uuid", "name": "...", "source": "schedule|fallback" },
  "items": [
    { "item_type": "media", "type": "video|image", "url": "https://signage-media.cutegory.cz/...", "sha256": "...", "duration_sec": 44 }
  ],
  "working_hours": { "tv_off": "02:00", "tv_on": "07:00" }
}
```

### Heartbeat endpoint
```
POST https://backoffice.cutegory.cz/api/v1/signage/heartbeat
Header: X-Device-Token: {device_key}
Content-Type: application/json

Body:
{ "device_id": "uuid", "ip_address": "...", "free_disk_mb": 1234, "uptime_sec": 5678, "player_status": "playing" }

Response: 204 No Content
```

---

## Reference

- **PiCast prototyp (reference):** `~/DEV/tools/picast/` — adaptovat bash klienta
- **Backoffice PRD:** `~/DEV/clients/Cutegory/cutegory-backoffice v2/docs/PRD-digital-signage.md`
- **Impl plán:** `~/DEV/clients/Cutegory/cutegory-backoffice v2/docs/IMPL-digital-signage.md`
