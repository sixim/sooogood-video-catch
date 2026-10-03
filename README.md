# Sooogood Video Catch

**English** · [Français](docs/README.fr.md) · [Deutsch](docs/README.de.md) · [日本語](docs/README.ja.md) · [한국어](docs/README.ko.md) · [中文](docs/README.zh-Hans.md)

A local-first macOS app for creators: save the best media streams a platform actually provides, download music in its original quality with tags, covers and lyrics, and hand everything to DaVinci Resolve as verifiable packages — every file with a SHA-256 manifest.

![Home](docs/images/home.png)

## Highlights

- **Video** — YouTube, Vimeo, Bilibili, Youku, HLS / DASH and the ~1,700 sites supported by [yt-dlp](https://github.com/yt-dlp/yt-dlp). A format inspector shows every stream (resolution, fps, codec, bitrate, size) before you download. Highest-quality mode merges the best video and audio without re-encoding.
- **Music download** — NetEase Cloud Music and QQ Music songs, albums, playlists, artists and charts. Quality follows your own account (up to lossless / Hi-Res for members). Tags, cover art and lyrics are written into the file, the real audio quality is measured after download, and songs you already have are detected and skipped.
- **Verifiable packages** — every download gets its own folder and a `manifest.json` with source, formats, tool versions and the SHA-256 of each file.
- **DaVinci Resolve** — one click imports a package into the current project's media pool (music lands in *Sooogood › Music › album*), with source, artist, album, measured quality and checksums as clip metadata.
- **Creator toolbox** — hardware ProRes Proxy / LT / 422, DNxHR, H.264 proxies, HEVC, lossless audio extraction, WAV, GIF and on-device whisper.cpp transcription.
- **Courses & playlists** — YouTube playlists, Udemy and Bilibili courses expand by chapter; DRM-protected lessons are skipped.
- **Torrents** — magnet links and `.torrent` files through a private, local Transmission engine, with file selection, sequential download and seeding limits.
- **AI agents (MCP)** — `sooogood-mcp` lets Claude Code, Hermes and other agents analyze, queue, check and send to Resolve. No delete operations are exposed.
- **Move to…** — move finished packages to another folder or disk; copies across disks are verified against the manifest before the original is removed.
- **Six languages** — English, Français, Deutsch, 日本語, 한국어, 中文.

| Video analysis | Music download |
|---|---|
| ![Video](docs/images/video.png) | ![Music](docs/images/music.png) |

| Downloads | Toolbox |
|---|---|
| ![Downloads](docs/images/downloads.png) | ![Toolbox](docs/images/toolbox.png) |

## Requirements

- macOS 14 Sonoma or later
- [Homebrew](https://brew.sh) for the command-line engines (the app never downloads executables itself):

```bash
brew install yt-dlp ffmpeg deno
```

Optional, only for the matching features:

```bash
brew install transmission-cli whisper-cpp
```

## Build and run

```bash
git clone <this repository>
cd "Youtube Download App"
./Scripts/package_app.sh
open "dist/Sooogood Video Catch.app"
```

For development: `swift run MediaFetch`. Tests: `swift test`.

Connect an AI agent (the exact path is also shown in *Settings › AI Agent*):

```bash
claude mcp add sooogood -- "/path/to/Sooogood Video Catch.app/Contents/MacOS/sooogood-mcp"
```

## Sign-in and privacy

- Site sign-in happens in a separate in-app WebKit window per platform, or by reusing the session of a browser you choose. Cookies are only exported to a private temporary file for the local engine and deleted afterwards; history and manifests never contain cookie data.
- Spotify is used through official OAuth (PKCE) for track identity and order only; tokens live in the macOS Keychain. Spotify audio is never downloaded.
- No telemetry, ads or tracking. Nothing is uploaded to any Sooogood server.

## Limits, on purpose

- No DRM circumvention (Netflix titles, protected Spotify audio, DRM course lessons are refused or skipped).
- Music quality depends on your own account. Tracks a platform has no rights to are flagged as such, and region checks are not bypassed.
- QQ Music works with a QQ-number sign-in; WeChat sign-in is not supported by the download engine.
- Sites change often — keep yt-dlp current with `brew upgrade yt-dlp`.

**Only download content you own, are licensed for, or that the platform explicitly allows you to save.**

## Documentation

- [Architecture](ARCHITECTURE.md) — modules and dependency rules
- [Developer guide (Chinese)](docs/DEVELOPMENT.zh-Hans.md) — profiles, packaging, release checks, platform details
- [Changelog](CHANGELOG.md)
- [Brochure](docs/brochure/) — two-page PDF in six languages ([EN](docs/brochure/Sooogood-Video-Catch-en.pdf) · [FR](docs/brochure/Sooogood-Video-Catch-fr.pdf) · [DE](docs/brochure/Sooogood-Video-Catch-de.pdf) · [JA](docs/brochure/Sooogood-Video-Catch-ja.pdf) · [KO](docs/brochure/Sooogood-Video-Catch-ko.pdf) · [中文](docs/brochure/Sooogood-Video-Catch-zh-Hans.pdf)); rebuild with `python3 Scripts/build_brochure.py`

---

Screenshot of *Big Buck Bunny* © Blender Foundation, [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).
