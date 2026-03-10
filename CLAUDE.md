# Cutegory Pi Client — Claude Instructions

## Projekt

Bash daemon pro Raspberry Pi 4, přehrává signage obsah (videa/fotky) z Cutegory Backoffice.

- **Runtime:** Raspberry Pi OS Lite (64-bit), bash, mpv, curl, jq, cec-client
- **Jazyk:** Bash (POSIX-compatible kde možné)

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
