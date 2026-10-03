# Sooogood Video Catch

[English](../README.md) · [Français](README.fr.md) · **Deutsch** · [日本語](README.ja.md) · [한국어](README.ko.md) · [中文](README.zh-Hans.md)

Eine lokal ausgerichtete macOS-App für Kreative: Sichere die besten Medienstreams, die eine Plattform tatsächlich liefert, lade Musik in Originalqualität mit Tags, Cover und Songtexten und übergib alles als prüfbare Pakete an DaVinci Resolve – jede Datei mit SHA-256-Manifest.

![Start](images/home.png)

## Installation in einer Zeile

Ins Terminal einfügen (oder einem KI-Agent geben):

```bash
curl -fsSL https://raw.githubusercontent.com/sixim/sooogood-video-catch/main/install.sh | bash
```

Das Skript lädt die neueste Version (Universal: Apple Silicon + Intel), prüft SHA-256 und Signatur, installiert nach /Applications und richtet yt-dlp, FFmpeg und deno über [Homebrew](https://brew.sh) ein. Ohne sudo, ohne Rückfragen. Für Agents – registriert zusätzlich den MCP-Server in Claude Code:

```bash
curl -fsSL https://raw.githubusercontent.com/sixim/sooogood-video-catch/main/install.sh | bash -s -- --with-mcp
```

Weitere Optionen: `--no-deps`, `--dir <Ordner>`, `--version vX.Y.Z`, `--open`. Die App ist ad hoc signiert (nicht notarisiert); lädst du das Zip stattdessen im Browser von der Releases-Seite, öffne sie beim ersten Mal per Rechtsklick → Öffnen.

## Highlights

- **Video** – YouTube, Vimeo, Bilibili, Youku, HLS / DASH und rund 1.700 von [yt-dlp](https://github.com/yt-dlp/yt-dlp) unterstützte Websites. Der Format-Inspektor zeigt vor dem Download jeden Stream (Auflösung, fps, Codec, Bitrate, Größe). „Höchste Qualität“ führt das beste Video und Audio ohne Neukodierung zusammen.
- **Musik-Download** – Titel, Alben, Playlists, Künstler und Charts von NetEase Cloud Music und QQ Music. Die Qualität richtet sich nach deinem eigenen Konto (bis verlustfrei / Hi-Res für Mitglieder). Tags, Cover und Songtexte werden in die Datei geschrieben, die tatsächliche Qualität wird nach dem Download gemessen, und bereits vorhandene Titel werden erkannt und übersprungen.
- **Prüfbare Pakete** – jeder Download erhält einen eigenen Ordner und eine `manifest.json` mit Quelle, Formaten, Werkzeugversionen und dem SHA-256 jeder Datei.
- **DaVinci Resolve** – ein Klick importiert ein Paket in den Media Pool des aktuellen Projekts (Musik landet in *Sooogood › Musik › Album*), mit Quelle, Künstler, Album, gemessener Qualität und Prüfsummen als Clip-Metadaten.
- **Werkzeugkasten** – Hardware-ProRes Proxy / LT / 422, DNxHR, H.264-Proxys, HEVC, verlustfreie Audio-Extraktion, WAV, GIF und whisper.cpp-Transkription auf dem Gerät.
- **Kurse & Playlists** – YouTube-Playlists sowie Udemy- und Bilibili-Kurse werden nach Kapiteln aufgeklappt; DRM-geschützte Lektionen werden übersprungen.
- **Torrents** – Magnet-Links und `.torrent`-Dateien über eine private, lokale Transmission-Engine, mit Dateiauswahl, sequenziellem Download und Seed-Grenzen.
- **KI-Agents (MCP)** – `sooogood-mcp` lässt Claude Code, Hermes und andere Agents analysieren, einreihen, prüfen und an Resolve senden. Löschfunktionen gibt es nicht.
- **Verschieben nach …** – fertige Pakete in einen anderen Ordner oder auf einen anderen Datenträger verschieben; Kopien zwischen Datenträgern werden vor dem Löschen des Originals gegen das Manifest geprüft.
- **Sechs Sprachen** – English, Français, Deutsch, 日本語, 한국어, 中文.

| Videoanalyse | Musik-Download |
|---|---|
| ![Video](images/video.png) | ![Musik](images/music.png) |

| Downloads | Werkzeugkasten |
|---|---|
| ![Downloads](images/downloads.png) | ![Werkzeugkasten](images/toolbox.png) |

*Bildschirmfotos auf Englisch; die App folgt der macOS-Sprache oder der Auswahl unter Einstellungen › Language · 语言.*

## Promo-Kit

Neun 1080×1080-Karten für soziale Netzwerke (3×3-Raster, in Reihenfolge, auf Englisch). Dateien: [promo](promo/) · neu erzeugen mit `python3 Scripts/build_promo.py`.

| | | |
|---|---|---|
| <img src="promo/01.png" width="260"> | <img src="promo/02.png" width="260"> | <img src="promo/03.png" width="260"> |
| <img src="promo/04.png" width="260"> | <img src="promo/05.png" width="260"> | <img src="promo/06.png" width="260"> |
| <img src="promo/07.png" width="260"> | <img src="promo/08.png" width="260"> | <img src="promo/09.png" width="260"> |

## Voraussetzungen

- macOS 14 Sonoma oder neuer
- [Homebrew](https://brew.sh) für die Kommandozeilen-Engines (die App lädt nie selbst ausführbare Dateien):

```bash
brew install yt-dlp ffmpeg deno
```

Optional, nur für die jeweiligen Funktionen:

```bash
brew install transmission-cli whisper-cpp
```

## Bauen und starten

```bash
git clone https://github.com/sixim/sooogood-video-catch.git
cd sooogood-video-catch
./Scripts/package_app.sh
open "dist/Sooogood Video Catch.app"
```

Entwicklung: `swift run MediaFetch`. Tests: `swift test`.

KI-Agent verbinden (der genaue Pfad steht auch unter *Einstellungen › AI Agent*):

```bash
claude mcp add sooogood -- "/pfad/zu/Sooogood Video Catch.app/Contents/MacOS/sooogood-mcp"
```

## Anmeldung und Datenschutz

- Die Anmeldung bei Websites erfolgt in einem eigenen WebKit-Fenster pro Plattform in der App oder über die Sitzung eines Browsers deiner Wahl. Cookies werden nur in eine private temporäre Datei für die lokale Engine exportiert und danach gelöscht; Verlauf und Manifeste enthalten nie Cookie-Daten.
- Spotify wird über das offizielle OAuth (PKCE) nur für Titelidentität und Reihenfolge genutzt; Tokens liegen im macOS-Schlüsselbund. Spotify-Audio wird nie geladen.
- Keine Telemetrie, keine Werbung, kein Tracking. Nichts wird auf einen Sooogood-Server hochgeladen.

## Bewusste Grenzen

- Keine Umgehung von DRM (Netflix-Titel, geschütztes Spotify-Audio, DRM-Lektionen werden abgelehnt oder übersprungen).
- Die Musikqualität hängt von deinem Konto ab. Titel ohne Rechte auf der Plattform werden gekennzeichnet; Regionsprüfungen werden nicht umgangen.
- QQ Music funktioniert mit Anmeldung per QQ-Nummer; WeChat-Anmeldung unterstützt die Engine nicht.
- Websites ändern sich oft – halte yt-dlp mit `brew upgrade yt-dlp` aktuell.

**Lade nur Inhalte, die dir gehören, für die du eine Lizenz hast oder deren Speicherung die Plattform ausdrücklich erlaubt.**

## Lizenz

GPL-3.0 – siehe [LICENSE](../LICENSE). Die externen Engines (yt-dlp, FFmpeg, deno, Transmission, whisper.cpp) sind nicht enthalten; sie werden separat über Homebrew installiert und behalten ihre eigenen Lizenzen.

## Dokumentation

- [Architektur](../ARCHITECTURE.md) · [Entwicklerhandbuch (Chinesisch)](DEVELOPMENT.zh-Hans.md) · [Änderungsprotokoll](../CHANGELOG.md) · [Broschüre](brochure/Sooogood-Video-Catch-de.pdf)

---

Bildschirmfoto von *Big Buck Bunny* © Blender Foundation, [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).
