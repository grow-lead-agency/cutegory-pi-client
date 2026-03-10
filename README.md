# Cutegory PiCast Client

Bash daemon pro Raspberry Pi 4, přehrává signage obsah z [Cutegory Backoffice](https://backoffice.cutegory.cz).

## Požadavky

- Raspberry Pi 4 (ARM64) s Raspberry Pi OS Lite
- HDMI připojená TV
- WiFi / Ethernet připojení

## Instalace

```bash
# 1. Naklonuj repo na Pi
git clone https://github.com/grow-lead-agency/cutegory-pi-client.git
cd cutegory-pi-client

# 2. Spusť instalátor (jako root)
sudo ./install.sh

# 3. Nastav config
sudo nano /opt/picast/config.env
# Vyplň DEVICE_ID a DEVICE_KEY z backoffice

# 4. Spusť
sudo systemctl start picast

# 5. Monitoruj
journalctl -u picast -f
```

## Jak to funguje

1. **picast-client.sh** — hlavní daemon loop, polluje backoffice API každých 30s
2. **sync.sh** — stahuje nová média z Cloudflare R2, maže stará, ověřuje SHA-256
3. **player.sh** — spravuje mpv přehrávač (fullscreen, HW dekódování, loop)
4. **cec-control.sh** — HDMI CEC ovládání TV (zapnutí/vypnutí podle pracovní doby)

## Konfigurace

Viz [config.env.example](config.env.example) pro všechny volby.

## Aktualizace

```bash
cd /opt/picast-repo  # nebo kam jsi naklonoval
git pull
sudo ./install.sh    # přepíše skripty, nechá config.env
sudo systemctl restart picast
```

## Odinstalace

```bash
sudo ./uninstall.sh
```
