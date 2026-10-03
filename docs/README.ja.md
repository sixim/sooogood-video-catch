# Sooogood Video Catch

[English](../README.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · **日本語** · [한국어](README.ko.md) · [中文](README.zh-Hans.md)

クリエイターのための、ローカル優先の macOS アプリ。プラットフォームが実際に提供する最高のメディアストリームを保存し、音楽はタグ・カバー・歌詞付きの元音質でダウンロード。すべてを検証可能なパッケージ（ファイルごとの SHA-256 マニフェスト付き）として DaVinci Resolve に渡せます。

![ホーム](images/home.png)

## 主な機能

- **動画** — YouTube、Vimeo、Bilibili、Youku、HLS / DASH、そして [yt-dlp](https://github.com/yt-dlp/yt-dlp) が対応する約 1,700 のサイト。フォーマット確認でダウンロード前にすべてのストリーム（解像度、fps、コーデック、ビットレート、サイズ）を表示。最高画質モードは最良の映像と音声を再エンコードせずに結合します。
- **音楽ダウンロード** — NetEase Cloud Music と QQ 音楽のシングル、アルバム、プレイリスト、アーティスト、ランキング。音質はあなた自身のアカウントに従います（会員ならロスレス / Hi-Res まで）。タグ・カバー・歌詞をファイルに書き込み、ダウンロード後に実際の音質を測定。手元にある曲は検出してスキップします。
- **検証可能なパッケージ** — ダウンロードごとに専用フォルダを作り、ソース、形式、ツールのバージョン、各ファイルの SHA-256 を記録した `manifest.json` を生成。
- **DaVinci Resolve** — ワンクリックで現在のプロジェクトのメディアプールにパッケージを読み込み（音楽は *Sooogood › 音楽 › アルバム* へ）、ソース、アーティスト、アルバム、実測音質、チェックサムをクリップのメタデータに書き込みます。
- **ツールボックス** — ハードウェア ProRes Proxy / LT / 422、DNxHR、H.264 プロキシ、HEVC、無劣化の音声抽出、WAV、GIF、ローカルの whisper.cpp 文字起こし。
- **コースとプレイリスト** — YouTube プレイリスト、Udemy と Bilibili の講座をチャプターごとに展開。DRM で保護されたレクチャーはスキップ。
- **トレント** — マグネットリンクと `.torrent` ファイルを、ローカル専用の Transmission エンジンで。ファイル選択、順番ダウンロード、シード制限に対応。
- **AI エージェント（MCP）** — `sooogood-mcp` で Claude Code、Hermes などのエージェントが解析、キュー追加、確認、Resolve への送信を行えます。削除操作は公開していません。
- **移動先…** — 完了したパッケージを別のフォルダやディスクへ移動。ディスク間のコピーは、元ファイルを削除する前にマニフェストで検証します。
- **6 言語** — English、Français、Deutsch、日本語、한국어、中文。

| 動画の解析 | 音楽ダウンロード |
|---|---|
| ![動画](images/video.png) | ![音楽](images/music.png) |

| ダウンロード | ツールボックス |
|---|---|
| ![ダウンロード](images/downloads.png) | ![ツールボックス](images/toolbox.png) |

*スクリーンショットは英語表示です。アプリは macOS の言語、または 設定 › Language · 语言 で選んだ言語で表示されます。*

## 動作環境

- macOS 14 Sonoma 以降
- コマンドラインエンジンは [Homebrew](https://brew.sh) で導入します（アプリが実行ファイルを自らダウンロードすることはありません）：

```bash
brew install yt-dlp ffmpeg deno
```

必要な機能に応じて（任意）：

```bash
brew install transmission-cli whisper-cpp
```

## ビルドと起動

```bash
./Scripts/package_app.sh
open "dist/Sooogood Video Catch.app"
```

開発時：`swift run MediaFetch`。テスト：`swift test`。

AI エージェントの接続（正確なパスは *設定 › AI Agent* にも表示されます）：

```bash
claude mcp add sooogood -- "/path/to/Sooogood Video Catch.app/Contents/MacOS/sooogood-mcp"
```

## ログインとプライバシー

- サイトへのログインは、プラットフォームごとに独立したアプリ内 WebKit ウィンドウで行うか、選んだブラウザのセッションを再利用します。Cookie はローカルエンジン用の非公開の一時ファイルにだけ書き出し、終了後に削除。履歴やマニフェストに Cookie は含まれません。
- Spotify は公式 OAuth（PKCE）で曲の識別情報と順序だけに使い、トークンは macOS キーチェーンに保存。Spotify の音声はダウンロードしません。
- テレメトリー、広告、トラッキングはありません。Sooogood のサーバーには何も送信しません。

## 意図した制限

- DRM は回避しません（Netflix の作品、保護された Spotify 音声、DRM 付きレクチャーは拒否またはスキップ）。
- 音楽の音質はあなたのアカウント次第です。プラットフォームに権利がない曲はその旨を表示し、地域制限も回避しません。
- QQ 音楽は QQ 番号でのログインで動作します。WeChat ログインにはダウンロードエンジンが対応していません。
- サイトは頻繁に変わります。`brew upgrade yt-dlp` で yt-dlp を最新に保ってください。

**権利を持っている、許諾を得ている、またはプラットフォームが保存を明示的に許可しているコンテンツだけをダウンロードしてください。**

## ドキュメント

- [アーキテクチャ](../ARCHITECTURE.md) · [開発者ガイド（中国語）](DEVELOPMENT.zh-Hans.md) · [変更履歴](../CHANGELOG.md) · [パンフレット](brochure/Sooogood-Video-Catch-ja.pdf)

---

*Big Buck Bunny* のスクリーンショット © Blender Foundation、[CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)。
