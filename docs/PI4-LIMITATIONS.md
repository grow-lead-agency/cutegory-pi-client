# PiCast — Pi 4 Limitations & Lessons Learned

> Postmortem z 11.3.2026 — hodinu jsme debuggovali "software bug" který byl HW limit.

## TL;DR

**Pi 4 (2-4GB RAM) NEDOKÁŽE běžet Chromium + mpv + Xorg současně.**
Jediný stabilní mode = media-only DRM (mpv přímo na framebuffer).

---

## CRITICAL: Chromium na Pi 4 = OOM crash

- Chromium sežere 300-500MB RAM, mpv ~100MB, Xorg ~50MB → OOM killer
- "Modrá obrazovka" = Samsung monitor "No Signal" po Pi crash, NE software bug
- Pi se po OOM crashu musí fyzicky restartovat (power cycle)

## Hybrid mode (mpv + Chromium) — NEFUNKČNÍ na Pi 4

Testované přístupy (všechny selhaly kvůli OOM):

1. **Kill/restart mpv** mezi segmenty → monitor blikne modře (HDMI signal loss)
2. **Overlap transitions** (start new before kill old) → 2 procesy = ještě víc RAM
3. **Persistent mpv** (`--idle=yes --force-window=yes`) + IPC socket → Chromium OOM
4. **Black wrapper HTML** (iframe) → stále OOM
5. **`--default-background-color=000000`** → CHYBA: alpha=00 = transparentní! Správně: `ff000000`

## Media-only DRM = jediný stabilní mode na Pi 4

```bash
mpv --vo=drm --gpu-context=drm --loop-playlist=inf playlist.m3u
```

- Přímo na framebuffer, žádný Xorg
- Minimální RAM, HW decode, žádné window management problémy
- Playlist loop = rock solid

## Pokud web obsah v budoucnu

| Řešení | Popis |
|--------|-------|
| **Pi 5 (8GB)** | Hybrid mode by měl fungovat |
| **Server-side render** | Renderovat HTML do obrázku/videa na serveru, poslat jako médium |
| **zswap/swap** | Přidat swap file na Pi 4 (ale pomalé na SD kartě) |
| **Lightweight browser** | `surf` nebo `luakit` místo Chromia (~50MB vs ~400MB) |

## Samsung S34CG50 ultrawide

- Rozlišení: 3440x1440
- "No Signal" screen = **jasně modrá** (snadno zaměnitelná za software bug!)
- Velmi citlivý na HDMI signal disruption — blikne modře i při sub-sekundovém výpadku

## VT7 framebuffer

Pi OS default VT console může být modrá/barevná. Fix:

```bash
setterm --background black --foreground black --clear all > /dev/tty7
```

Systemd oneshot service `picast-vt-black.service` to řeší při bootu.

## Player.sh verze

| Verze | Popis | Status |
|-------|-------|--------|
| v5 | Hybrid orchestrator (kill/restart) | Nestabilní |
| v6 | Persistent mpv + IPC socket | OOM na Pi 4 |
| **Produkční** | Media-only DRM loop | Stable |

Chromium kód v player.sh ZŮSTÁVÁ (pro budoucí Pi 5), ale na Pi 4 se nepoužívá.

## SSH / Remote debug tipy

```bash
# X11 screenshot
scrot /tmp/screen.png

# Framebuffer screenshot
fbgrab /tmp/fb.png

# mpv IPC
echo '{"command":["get_property","path"]}' | socat - /opt/picast/.mpv-socket

# Užitečné mpv IPC příkazy
# loadlist, set_property pause, get_property idle-active
```
