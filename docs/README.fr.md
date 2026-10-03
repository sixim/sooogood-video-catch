# Sooogood Video Catch

[English](../README.md) · **Français** · [Deutsch](README.de.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [中文](README.zh-Hans.md)

Une app macOS locale avant tout, pensée pour les créateurs : enregistrez les meilleurs flux réellement fournis par une plateforme, téléchargez la musique dans sa qualité d’origine avec tags, pochette et paroles, puis transmettez le tout à DaVinci Resolve sous forme de paquets vérifiables — chaque fichier avec un manifeste SHA-256.

![Accueil](images/home.png)

## Points forts

- **Vidéo** — YouTube, Vimeo, Bilibili, Youku, HLS / DASH et les quelque 1 700 sites pris en charge par [yt-dlp](https://github.com/yt-dlp/yt-dlp). L’inspecteur de format affiche chaque flux (résolution, fps, codec, débit, taille) avant le téléchargement. Le mode Qualité maximale fusionne la meilleure vidéo et le meilleur audio sans réencodage.
- **Téléchargement musical** — titres, albums, playlists, artistes et classements de NetEase Cloud Music et QQ Music. La qualité dépend de votre propre compte (jusqu’au sans perte / Hi-Res pour les membres). Tags, pochette et paroles sont écrits dans le fichier, la qualité réelle est mesurée après téléchargement, et les titres déjà présents sont détectés et ignorés.
- **Paquets vérifiables** — chaque téléchargement a son propre dossier et un `manifest.json` avec la source, les formats, les versions des outils et le SHA-256 de chaque fichier.
- **DaVinci Resolve** — un clic importe un paquet dans le pool de médias du projet actuel (la musique va dans *Sooogood › Musique › album*), avec source, artiste, album, qualité mesurée et sommes de contrôle en métadonnées.
- **Boîte à outils** — ProRes Proxy / LT / 422 matériel, DNxHR, proxys H.264, HEVC, extraction audio sans perte, WAV, GIF et transcription locale whisper.cpp.
- **Cours et playlists** — playlists YouTube, cours Udemy et Bilibili développés par chapitre ; les leçons protégées par DRM sont ignorées.
- **Torrents** — liens magnet et fichiers `.torrent` via un moteur Transmission local et privé, avec choix des fichiers, téléchargement séquentiel et limites de partage.
- **Agents IA (MCP)** — `sooogood-mcp` permet à Claude Code, Hermes et d’autres agents d’analyser, mettre en file, vérifier et envoyer vers Resolve. Aucune suppression n’est exposée.
- **Déplacer vers…** — déplacez les paquets terminés vers un autre dossier ou disque ; les copies entre disques sont vérifiées via le manifeste avant la suppression de l’original.
- **Six langues** — English, Français, Deutsch, 日本語, 한국어, 中文.

| Analyse vidéo | Téléchargement musical |
|---|---|
| ![Vidéo](images/video.png) | ![Musique](images/music.png) |

| Téléchargements | Boîte à outils |
|---|---|
| ![Téléchargements](images/downloads.png) | ![Boîte à outils](images/toolbox.png) |

*Captures d’écran en anglais ; l’app suit la langue de macOS ou celle choisie dans Réglages › Language · 语言.*

## Kit promotionnel

Neuf visuels 1080×1080 pour les réseaux sociaux (grille 3×3, dans l’ordre, en anglais). Fichiers : [promo](promo/) · régénérer avec `python3 Scripts/build_promo.py`.

| | | |
|---|---|---|
| <img src="promo/01.png" width="260"> | <img src="promo/02.png" width="260"> | <img src="promo/03.png" width="260"> |
| <img src="promo/04.png" width="260"> | <img src="promo/05.png" width="260"> | <img src="promo/06.png" width="260"> |
| <img src="promo/07.png" width="260"> | <img src="promo/08.png" width="260"> | <img src="promo/09.png" width="260"> |

## Configuration requise

- macOS 14 Sonoma ou ultérieur
- [Homebrew](https://brew.sh) pour les moteurs en ligne de commande (l’app ne télécharge jamais d’exécutables elle-même) :

```bash
brew install yt-dlp ffmpeg deno
```

Facultatif, seulement pour les fonctions correspondantes :

```bash
brew install transmission-cli whisper-cpp
```

## Compiler et lancer

```bash
./Scripts/package_app.sh
open "dist/Sooogood Video Catch.app"
```

Développement : `swift run MediaFetch`. Tests : `swift test`.

Connecter un agent IA (le chemin exact figure aussi dans *Réglages › AI Agent*) :

```bash
claude mcp add sooogood -- "/chemin/vers/Sooogood Video Catch.app/Contents/MacOS/sooogood-mcp"
```

## Connexion et confidentialité

- La connexion aux sites se fait dans une fenêtre WebKit intégrée et séparée par plateforme, ou en réutilisant la session d’un navigateur de votre choix. Les cookies ne sont exportés que vers un fichier temporaire privé pour le moteur local, puis supprimés ; l’historique et les manifestes n’en contiennent jamais.
- Spotify est utilisé via l’OAuth officiel (PKCE), uniquement pour l’identité et l’ordre des titres ; les jetons restent dans le trousseau macOS. L’audio Spotify n’est jamais téléchargé.
- Ni télémétrie, ni publicité, ni suivi. Rien n’est envoyé à un serveur Sooogood.

## Limites voulues

- Aucun contournement de DRM (œuvres Netflix, audio Spotify protégé, leçons sous DRM : refusés ou ignorés).
- La qualité musicale dépend de votre compte. Les titres sur lesquels une plateforme n’a pas de droits sont signalés, et les restrictions régionales ne sont pas contournées.
- QQ Music fonctionne avec une connexion par numéro QQ ; la connexion WeChat n’est pas prise en charge par le moteur.
- Les sites changent souvent — tenez yt-dlp à jour avec `brew upgrade yt-dlp`.

**Ne téléchargez que des contenus qui vous appartiennent, pour lesquels vous avez une licence, ou que la plateforme autorise explicitement à enregistrer.**

## Licence

GPL-3.0 — voir [LICENSE](../LICENSE). Les moteurs externes (yt-dlp, FFmpeg, deno, Transmission, whisper.cpp) ne sont pas inclus ; ils s’installent séparément via Homebrew et conservent leurs propres licences.

## Documentation

- [Architecture](../ARCHITECTURE.md) · [Guide développeur (chinois)](DEVELOPMENT.zh-Hans.md) · [Journal des modifications](../CHANGELOG.md) · [Brochure](brochure/Sooogood-Video-Catch-fr.pdf)

---

Capture de *Big Buck Bunny* © Blender Foundation, [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).
