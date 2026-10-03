#!/usr/bin/env python3
"""Builds the two-page product brochure (A4 landscape) in six languages.

Output: docs/brochure/Sooogood-Video-Catch-<lang>.pdf, rendered by headless
Google Chrome from generated HTML. Screenshots come from docs/images/; the
logo is Resources/Brand/MediaFetchLogo.svg. Colors follow BrandGuidelines.md.

    python3 Scripts/build_brochure.py            # all languages
    python3 Scripts/build_brochure.py en ja      # selected languages
"""
import html
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT = ROOT / "docs" / "brochure"

TEXT = {
    "en": dict(
        lang="en", stats=[("≈1,700","sites via yt-dlp"),("SHA-256","for every file"),("6","interface languages"),("0","telemetry or ads")], tagline="Save what you're allowed to keep — in the best quality, with proof.",
        sub="A local-first macOS app for creators: video, music, courses and torrents, delivered as verifiable packages and ready for DaVinci Resolve.",
        pillars=["Original quality", "SHA-256 manifests", "Ready for Resolve"],
        caps=[("Video, inspected first", "Every stream with resolution, codec, bitrate and size before you download."),
              ("Music in original quality", "NetEase Cloud Music & QQ Music: tags, cover, lyrics, measured quality, duplicates skipped."),
              ("A queue you can audit", "Analyze → download → merge → verify → manifest, with the exact command kept."),
              ("A toolbox for editors", "ProRes / DNxHR proxies, HEVC, WAV, GIF and on-device transcription.")],
        feats=[("DaVinci Resolve", "One click into the media pool, with source and checksums as clip metadata."),
               ("AI agents (MCP)", "Claude Code, Hermes and others can analyze, queue and send — never delete."),
               ("Courses & playlists", "Expanded by chapter; DRM lessons skipped."),
               ("Torrents", "Private local Transmission engine, file selection, seeding limits."),
               ("Move to…", "Across disks with verification before the original is removed."),
               ("Six languages", "English · Français · Deutsch · 日本語 · 한국어 · 中文")],
        req_title="Requirements", req="macOS 14 or later · yt-dlp, FFmpeg and deno via Homebrew",
        use_title="Responsible use", use="No DRM circumvention. Download only content you own, are licensed for, or that the platform allows you to save.",
        page2="Everything in one place", credit="Big Buck Bunny screenshot © Blender Foundation, CC BY 3.0"),
    "fr": dict(
        lang="fr", stats=[("≈1 700","sites via yt-dlp"),("SHA-256","pour chaque fichier"),("6","langues d’interface"),("0","télémétrie ou publicité")], tagline="Gardez ce que vous avez le droit de garder — en meilleure qualité, avec preuves.",
        sub="Une app macOS locale avant tout pour les créateurs : vidéo, musique, cours et torrents, livrés en paquets vérifiables et prêts pour DaVinci Resolve.",
        pillars=["Qualité d’origine", "Manifestes SHA-256", "Prêt pour Resolve"],
        caps=[("La vidéo, inspectée d’abord", "Chaque flux avec résolution, codec, débit et taille avant le téléchargement."),
              ("La musique en qualité d’origine", "NetEase Cloud Music et QQ Music : tags, pochette, paroles, qualité mesurée, doublons ignorés."),
              ("Une file vérifiable", "Analyse → téléchargement → fusion → vérification → manifeste, commande exacte conservée."),
              ("Une boîte à outils de monteur", "Proxys ProRes / DNxHR, HEVC, WAV, GIF et transcription locale.")],
        feats=[("DaVinci Resolve", "Un clic vers le pool de médias, source et sommes de contrôle en métadonnées."),
               ("Agents IA (MCP)", "Claude Code, Hermes et d’autres analysent, mettent en file, envoient — sans jamais supprimer."),
               ("Cours et playlists", "Développés par chapitre ; leçons sous DRM ignorées."),
               ("Torrents", "Moteur Transmission local et privé, choix des fichiers, limites de partage."),
               ("Déplacer vers…", "Entre disques, avec vérification avant la suppression de l’original."),
               ("Six langues", "English · Français · Deutsch · 日本語 · 한국어 · 中文")],
        req_title="Configuration", req="macOS 14 ou ultérieur · yt-dlp, FFmpeg et deno via Homebrew",
        use_title="Usage responsable", use="Aucun contournement de DRM. Ne téléchargez que ce qui vous appartient, est sous licence ou est autorisé par la plateforme.",
        page2="Tout au même endroit", credit="Capture de Big Buck Bunny © Blender Foundation, CC BY 3.0"),
    "de": dict(
        lang="de", stats=[("≈1.700","Websites über yt-dlp"),("SHA-256","für jede Datei"),("6","Oberflächensprachen"),("0","Telemetrie oder Werbung")], tagline="Behalte, was du behalten darfst – in bester Qualität, mit Nachweis.",
        sub="Eine lokal ausgerichtete macOS-App für Kreative: Video, Musik, Kurse und Torrents als prüfbare Pakete, bereit für DaVinci Resolve.",
        pillars=["Originalqualität", "SHA-256-Manifeste", "Bereit für Resolve"],
        caps=[("Video, zuerst geprüft", "Jeder Stream mit Auflösung, Codec, Bitrate und Größe vor dem Download."),
              ("Musik in Originalqualität", "NetEase Cloud Music & QQ Music: Tags, Cover, Songtexte, gemessene Qualität, Doppelte übersprungen."),
              ("Eine prüfbare Warteschlange", "Analyse → Download → Zusammenführen → Prüfen → Manifest, exakter Befehl gespeichert."),
              ("Werkzeugkasten für den Schnitt", "ProRes-/DNxHR-Proxys, HEVC, WAV, GIF und Transkription auf dem Gerät.")],
        feats=[("DaVinci Resolve", "Ein Klick in den Media Pool, Quelle und Prüfsummen als Clip-Metadaten."),
               ("KI-Agents (MCP)", "Claude Code, Hermes u. a. analysieren, reihen ein, senden – löschen nie."),
               ("Kurse & Playlists", "Nach Kapiteln aufgeklappt; DRM-Lektionen übersprungen."),
               ("Torrents", "Private lokale Transmission-Engine, Dateiauswahl, Seed-Grenzen."),
               ("Verschieben nach …", "Zwischen Datenträgern, geprüft vor dem Löschen des Originals."),
               ("Sechs Sprachen", "English · Français · Deutsch · 日本語 · 한국어 · 中文")],
        req_title="Voraussetzungen", req="macOS 14 oder neuer · yt-dlp, FFmpeg und deno über Homebrew",
        use_title="Verantwortungsvoll nutzen", use="Keine Umgehung von DRM. Lade nur, was dir gehört, lizenziert ist oder von der Plattform erlaubt wird.",
        page2="Alles an einem Ort", credit="Bildschirmfoto von Big Buck Bunny © Blender Foundation, CC BY 3.0"),
    "ja": dict(
        lang="ja", stats=[("約1,700","yt-dlp 対応サイト"),("SHA-256","すべてのファイルに"),("6","表示言語"),("0","テレメトリー・広告")], tagline="保存してよいものを、最高の品質で、証拠とともに。",
        sub="クリエイターのためのローカル優先 macOS アプリ。動画・音楽・講座・トレントを検証可能なパッケージにして、そのまま DaVinci Resolve へ。",
        pillars=["元の品質のまま", "SHA-256 マニフェスト", "Resolve にすぐ渡せる"],
        caps=[("まず確認してから動画を保存", "解像度・コーデック・ビットレート・サイズを、ダウンロード前にすべて表示。"),
              ("音楽は元の音質で", "NetEase Cloud Music と QQ 音楽。タグ・カバー・歌詞、実測音質、重複はスキップ。"),
              ("追跡できるキュー", "解析 → ダウンロード → 結合 → 検証 → マニフェスト。実行コマンドも記録。"),
              ("編集者のためのツールボックス", "ProRes / DNxHR プロキシ、HEVC、WAV、GIF、ローカル文字起こし。")],
        feats=[("DaVinci Resolve", "ワンクリックでメディアプールへ。ソースとチェックサムをメタデータに。"),
               ("AI エージェント（MCP）", "Claude Code や Hermes が解析・キュー追加・送信。削除はできません。"),
               ("コースとプレイリスト", "チャプターごとに展開。DRM 付きレクチャーはスキップ。"),
               ("トレント", "ローカル専用 Transmission エンジン、ファイル選択、シード制限。"),
               ("移動先…", "ディスク間でも、検証してから元ファイルを削除。"),
               ("6 言語", "English · Français · Deutsch · 日本語 · 한국어 · 中文")],
        req_title="動作環境", req="macOS 14 以降 · Homebrew で yt-dlp、FFmpeg、deno を導入",
        use_title="責任ある利用", use="DRM は回避しません。権利を持つ、許諾を得た、またはプラットフォームが保存を許可したコンテンツだけをダウンロードしてください。",
        page2="すべてをひとつに", credit="Big Buck Bunny のスクリーンショット © Blender Foundation, CC BY 3.0"),
    "ko": dict(
        lang="ko", stats=[("약 1,700","yt-dlp 지원 사이트"),("SHA-256","모든 파일에"),("6","인터페이스 언어"),("0","원격 측정·광고")], tagline="보관해도 되는 것을, 최고 품질로, 증거와 함께.",
        sub="크리에이터를 위한 로컬 우선 macOS 앱. 동영상·음악·강좌·토렌트를 검증 가능한 패키지로 만들어 DaVinci Resolve로 바로 넘깁니다.",
        pillars=["원본 품질 그대로", "SHA-256 매니페스트", "Resolve에 바로"],
        caps=[("먼저 확인하는 동영상", "다운로드 전에 모든 스트림의 해상도·코덱·비트레이트·크기를 표시."),
              ("원본 음질의 음악", "NetEase Cloud Music과 QQ 뮤직. 태그·커버·가사, 실측 음질, 중복은 건너뜀."),
              ("추적 가능한 대기열", "분석 → 다운로드 → 병합 → 검증 → 매니페스트, 실행한 명령까지 기록."),
              ("편집자를 위한 도구 상자", "ProRes / DNxHR 프록시, HEVC, WAV, GIF, 로컬 받아쓰기.")],
        feats=[("DaVinci Resolve", "클릭 한 번으로 미디어 풀로. 출처와 체크섬을 메타데이터로."),
               ("AI 에이전트(MCP)", "Claude Code, Hermes 등이 분석·대기열 추가·전송. 삭제는 불가."),
               ("강좌와 재생목록", "챕터별로 펼치고 DRM 강의는 건너뜀."),
               ("토렌트", "로컬 전용 Transmission 엔진, 파일 선택, 시딩 제한."),
               ("다음으로 이동…", "디스크 간에도 검증한 뒤에 원본 삭제."),
               ("6개 언어", "English · Français · Deutsch · 日本語 · 한국어 · 中文")],
        req_title="요구 사항", req="macOS 14 이상 · Homebrew로 yt-dlp, FFmpeg, deno 설치",
        use_title="책임 있는 사용", use="DRM을 우회하지 않습니다. 권리를 가졌거나 허가받았거나 플랫폼이 저장을 허용한 콘텐츠만 다운로드하세요.",
        page2="모든 것을 한곳에", credit="Big Buck Bunny 스크린샷 © Blender Foundation, CC BY 3.0"),
    "zh-Hans": dict(
        lang="zh-Hans", stats=[("约 1,700","个 yt-dlp 支持的网站"),("SHA-256","每个文件都有"),("6","种界面语言"),("0","遥测与广告")], tagline="把可以保存的，以最高质量、带着凭据，带回本地。",
        sub="为创作者设计、本地优先的 macOS 应用：视频、音乐、课程和 Torrent，都整理成可验证的素材包，直接交给达芬奇。",
        pillars=["原始质量", "SHA-256 清单", "直通达芬奇"],
        caps=[("先看清，再下载视频", "下载前列出每条流的分辨率、编码、码率和大小。"),
              ("原始音质的音乐", "网易云音乐、QQ 音乐：标签、封面、歌词，实测音质，本地已有自动跳过。"),
              ("可审计的下载队列", "解析 → 下载 → 合并 → 校验 → 清单，连实际执行的命令都留存。"),
              ("剪辑师的工具箱", "ProRes / DNxHR 代理、HEVC、WAV、GIF 和本机转录。")],
        feats=[("达芬奇对接", "一键进媒体池，来源和校验值写入片段元数据。"),
               ("AI agent（MCP）", "Claude Code、Hermes 等可以解析、入队、发送，但永远不能删除。"),
               ("课程与播放列表", "按章节展开，DRM 课时自动跳过。"),
               ("Torrent", "本机私有 Transmission 引擎，选文件、做种限制。"),
               ("移动到…", "跨磁盘也先校验，再删除原件。"),
               ("6 种语言", "English · Français · Deutsch · 日本語 · 한국어 · 中文")],
        req_title="运行环境", req="macOS 14 或更新 · 通过 Homebrew 安装 yt-dlp、FFmpeg、deno",
        use_title="合理使用", use="不绕过 DRM。仅下载你拥有权利、已获许可或平台允许保存的内容。",
        page2="一切，尽在一处", credit="Big Buck Bunny 截图 © Blender Foundation，CC BY 3.0"),
}

FONTS = {
    "ja": '"Hiragino Sans", "Hiragino Kaku Gothic ProN"',
    "ko": '"Apple SD Gothic Neo"',
    "zh-Hans": '"PingFang SC"',
}

CSS = """
@page { size: 297mm 210mm; margin: 0; }
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { background: #0A0C11; color: #F5F7FA; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { font-family: -apple-system, "SF Pro Text", %(font)s, "Helvetica Neue", sans-serif; }
.page { width: 297mm; height: 210mm; position: relative; overflow: hidden; page-break-after: always;
  background: radial-gradient(circle at 85%% 10%%, rgba(128,103,255,.22), transparent 42%%),
              radial-gradient(circle at 10%% 95%%, rgba(50,199,160,.16), transparent 40%%), #0A0C11; padding: 15mm 16mm; }
.page:last-child { page-break-after: auto; }
.brand { display: flex; align-items: center; gap: 5mm; }
.brand img { width: 18mm; height: 18mm; }
.brand .name { font-size: 22pt; font-weight: 700; letter-spacing: -.3pt; }
.brand .kind { font-size: 9pt; color: #9BA4B5; margin-top: 1mm; }
.cover { display: grid; grid-template-columns: 92mm 1fr; gap: 10mm; margin-top: 8mm; align-items: start; }
h1 { font-size: 25pt; line-height: 1.18; font-weight: 800; letter-spacing: -.4pt; color: #F5F7FA; }
h1::after { content: ""; display: block; width: 22mm; height: 1.2mm; margin-top: 5mm; border-radius: 1mm;
  background: linear-gradient(90deg, #4B8DFF, #8067FF, #32C7A0); }
.stats { position: absolute; left: 16mm; right: 16mm; bottom: 24mm; display: grid; grid-template-columns: repeat(4, 1fr); gap: 5mm; }
.stat { background: #141821; border: .3mm solid rgba(155,164,181,.18); border-radius: 3mm; padding: 4mm 5mm; }
.stat b { display: block; font-size: 17pt; font-weight: 750; color: #F5F7FA; }
.stat span { font-size: 8.5pt; color: #9BA4B5; }
.sub { font-size: 11pt; line-height: 1.55; color: #C9D0DC; margin-top: 6mm; }
.pills { display: flex; flex-wrap: wrap; gap: 2.5mm; margin-top: 8mm; }
.pill { font-size: 9pt; padding: 1.6mm 3.6mm; border-radius: 20mm; border: .3mm solid rgba(155,164,181,.35); background: #141821; }
.pill:nth-child(1) { border-color: #4B8DFF; } .pill:nth-child(2) { border-color: #8067FF; } .pill:nth-child(3) { border-color: #32C7A0; }
.shot { width: 100%%; border-radius: 3.2mm; border: .3mm solid rgba(155,164,181,.25); box-shadow: 0 6mm 16mm rgba(0,0,0,.55); display: block; }
.accent { position: absolute; left: 16mm; right: 16mm; bottom: 12mm; display: flex; justify-content: space-between; align-items: flex-end;
  font-size: 8pt; color: #9BA4B5; border-top: .3mm solid rgba(155,164,181,.2); padding-top: 3mm; }
h2 { font-size: 17pt; font-weight: 750; margin: 0 0 4mm; }
.grid { display: grid; grid-template-columns: 1fr 1fr 74mm; gap: 5mm; }
.col .shot { height: 60mm; object-fit: cover; object-position: top; }
.cap { margin-top: 2.2mm; } .cap b { display: block; font-size: 9.5pt; } .cap span { font-size: 8pt; color: #9BA4B5; line-height: 1.45; }
.col { display: grid; gap: 3.5mm; align-content: start; }
.side { background: #141821; border: .3mm solid rgba(155,164,181,.18); border-radius: 3.2mm; padding: 5mm; display: flex; flex-direction: column; gap: 3.2mm; }
.feat b { display: block; font-size: 9pt; } .feat span { font-size: 7.8pt; color: #9BA4B5; line-height: 1.4; }
.note { border-top: .3mm solid rgba(155,164,181,.18); padding-top: 3mm; }
.note b { font-size: 8.5pt; color: #8DE6CF; } .note p { font-size: 7.8pt; color: #C9D0DC; line-height: 1.45; margin-top: 1mm; }
"""

# CJK fonts have taller line boxes; keep page 2 inside the footer.
CJK_CSS = """
.feat span, .cap span, .note p { line-height: 1.32; }
.col .shot { height: 52mm; }
.side { gap: 2.2mm; padding: 4.5mm; }
"""


def page_html(t: dict, logo: pathlib.Path, images: pathlib.Path) -> str:
    e = html.escape
    img = lambda name: (images / f"{name}.png").as_uri()
    pills = "".join(f'<div class="pill">{e(p)}</div>' for p in t["pillars"])
    stats = "".join(f'<div class="stat"><b>{e(a)}</b><span>{e(b)}</span></div>' for a, b in t["stats"])
    shots = ["video", "music", "downloads", "toolbox"]
    caps = [f'<div><img class="shot" src="{img(s)}"><div class="cap"><b>{e(a)}</b><span>{e(b)}</span></div></div>'
            for s, (a, b) in zip(shots, t["caps"])]
    feats = "".join(f'<div class="feat"><b>{e(a)}</b><span>{e(b)}</span></div>' for a, b in t["feats"])
    brand = (f'<div class="brand"><img src="{logo.as_uri()}"><div><div class="name">Sooogood Video Catch</div>'
             f'<div class="kind">macOS · local-first media toolkit</div></div></div>')
    footer = f'<div class="accent"><span>Sooogood Video Catch</span><span>{e(t["credit"])}</span></div>'
    return f"""<!doctype html><html lang="{t['lang']}"><head><meta charset="utf-8">
<style>{CSS % {'font': FONTS.get(t['lang'], '"Helvetica Neue"')}}{CJK_CSS if t['lang'] in FONTS else ''}</style></head><body>
<section class="page">{brand}
  <div class="cover">
    <div><h1>{e(t['tagline'])}</h1><p class="sub">{e(t['sub'])}</p><div class="pills">{pills}</div></div>
    <img class="shot" src="{img('home')}">
  </div><div class="stats">{stats}</div>{footer}
</section>
<section class="page"><h2>{e(t['page2'])}</h2>
  <div class="grid">
    <div class="col">{caps[0]}{caps[2]}</div>
    <div class="col">{caps[1]}{caps[3]}</div>
    <div class="side">{feats}
      <div class="note"><b>{e(t['req_title'])}</b><p>{e(t['req'])}</p></div>
      <div class="note"><b>{e(t['use_title'])}</b><p>{e(t['use'])}</p></div>
    </div>
  </div>{footer}
</section></body></html>"""


def main(languages):
    OUT.mkdir(parents=True, exist_ok=True)
    logo = ROOT / "Resources" / "Brand" / "MediaFetchLogo.svg"
    images = ROOT / "docs" / "images"
    with tempfile.TemporaryDirectory() as tmp:
        for code in languages:
            source = pathlib.Path(tmp) / f"brochure-{code}.html"
            source.write_text(page_html(TEXT[code], logo, images), encoding="utf-8")
            target = OUT / f"Sooogood-Video-Catch-{code}.pdf"
            subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                            "--allow-file-access-from-files", f"--print-to-pdf={target}", source.as_uri()],
                           check=True, capture_output=True)
            print(target.relative_to(ROOT))


if __name__ == "__main__":
    main(sys.argv[1:] or list(TEXT))
