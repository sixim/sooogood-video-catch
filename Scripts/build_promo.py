#!/usr/bin/env python3
"""Builds the social promo set: nine 1080×1080 English images (a 3×3 grid
for WeChat Moments / Instagram) rendered by headless Chrome.

    python3 Scripts/build_promo.py [output-dir]     # default: dist/promo

Screenshots come from docs/images/, the logo from Resources/Brand/.
Values shown (quality, manifest fields, MCP output) are from real runs.
"""
import html
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
IMG = ROOT / "docs" / "images"
LOGO = (ROOT / "Resources" / "Brand" / "MediaFetchLogo.svg").as_uri()

CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { width: 1080px; height: 1080px; overflow: hidden; background: #0A0C11; }
body { font-family: -apple-system, "SF Pro Display", "PingFang SC", "Helvetica Neue", sans-serif; color: #F5F7FA; }
.card { position: relative; width: 1080px; height: 1080px; padding: 84px 84px 0;
  background: radial-gradient(circle at 88% 6%, rgba(128,103,255,.30), transparent 40%),
              radial-gradient(circle at 6% 96%, rgba(50,199,160,.20), transparent 42%), #0A0C11; }
.num { position: absolute; top: 48px; right: 60px; font-size: 22px; color: #6B7487; letter-spacing: 2px; }
.kicker { font-size: 24px; font-weight: 600; letter-spacing: 3px; text-transform: uppercase;
  background: linear-gradient(90deg, #4B8DFF, #8067FF, #32C7A0); -webkit-background-clip: text; color: transparent; }
h1 { font-size: 72px; line-height: 1.06; font-weight: 800; letter-spacing: -1.5px; margin-top: 18px; }
.sub { font-size: 29px; line-height: 1.42; color: #B8C0CE; margin-top: 22px; max-width: 900px; }
.shot { position: absolute; left: 84px; right: 84px; bottom: 120px; height: 470px; border-radius: 22px; overflow: hidden;
  border: 2px solid rgba(155,164,181,.22); box-shadow: 0 30px 80px rgba(0,0,0,.6); }
.shot img { width: 100%; display: block; }
.foot { position: absolute; left: 84px; right: 84px; bottom: 44px; display: flex; align-items: center; gap: 14px;
  font-size: 22px; color: #8A93A5; }
.foot img { width: 36px; height: 36px; }
.foot b { color: #D7DCE5; font-weight: 600; }
.badge { position: absolute; right: 120px; bottom: 150px; padding: 18px 26px; border-radius: 18px; font-size: 30px; font-weight: 700;
  background: rgba(20,24,33,.92); border: 2px solid #32C7A0; color: #8DE6CF; box-shadow: 0 16px 40px rgba(0,0,0,.5); }
.panel { position: absolute; left: 84px; right: 84px; bottom: 120px; border-radius: 22px; background: #141821;
  border: 2px solid rgba(155,164,181,.2); padding: 34px 40px; font-family: "SF Mono", Menlo, monospace; font-size: 24px; line-height: 1.55; }
.k { color: #8BB4FF; } .s { color: #8DE6CF; } .n { color: #F0C674; } .c { color: #6B7487; } .p { color: #B48CFF; }
.tree { font-family: -apple-system, "PingFang SC", sans-serif; font-size: 28px; line-height: 1.7; }
.row { display: flex; justify-content: space-between; border-top: 1px solid rgba(155,164,181,.15); padding: 9px 0; font-size: 23px; }
.row span:first-child { color: #8A93A5; }
.pills { display: flex; flex-wrap: wrap; gap: 16px; margin-top: 46px; }
.pill { font-size: 32px; padding: 14px 28px; border-radius: 40px; background: #141821; border: 2px solid rgba(155,164,181,.3); }
.facts { position: absolute; left: 84px; right: 84px; bottom: 130px; display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
.fact { background: #141821; border: 2px solid rgba(155,164,181,.18); border-radius: 20px; padding: 24px 28px; }
.fact b { display: block; font-size: 34px; } .fact span { font-size: 22px; color: #9BA4B5; }
.hero-logo { width: 150px; height: 150px; }
"""


def foot():
    return f'<div class="foot"><img src="{LOGO}"><b>Sooogood Video Catch</b> · for macOS</div>'


def shot(name, x=0, y=0, zoom=1.0):
    """Crop of a screenshot that always fills the frame: zoom enlarges,
    x / y (0–100 %) choose which part stays visible."""
    src = (IMG / f"{name}.png").as_uri()
    return (f'<div class="shot" style="background: #0A0C11 url(\'{src}\') no-repeat {x}% {y}% / {zoom * 100}% auto;"></div>')


def slide(i, kicker, title, sub, body):
    e = html.escape
    return (f'<div class="card"><div class="num">{i:02d} / 09</div><div class="kicker">{e(kicker)}</div>'
            f'<h1>{title}</h1><p class="sub">{e(sub)}</p>{body}{foot()}</div>')


SLIDES = [
    slide(1, "macOS · local-first · open source", "Save what you’re<br>allowed to keep.",
          "In the best quality the platform offers — with proof for every file.",
          shot("home", y=0)),
    slide(2, "Video", "See every stream<br>before you download.",
          "4K60, VP9, AV1, bitrate and size — YouTube, Vimeo, Bilibili and ~1,700 sites.",
          shot("video", x=0, y=100, zoom=1.2)),
    slide(3, "Music", "Music in its<br>original quality.",
          "NetEase Cloud Music & QQ Music — up to Hi-Res with your own membership. Tags, cover and lyrics included.",
          shot("music", y=0) + '<div class="badge">Measured: FLAC · 96 kHz · 24-bit</div>'),
    slide(4, "Library aware", "Already have it?<br>Skipped.",
          "Songs already on your Mac are found and left unselected. No duplicates.",
          shot("music", y=100)),
    slide(5, "Verifiable", "Proof for<br>every file.",
          "Each download gets its own folder and a manifest.json with source, formats, tools and SHA-256.",
          '<div class="panel">'
          '<span class="c">// manifest.json (excerpt)</span><br>'
          '<span class="k">"title"</span>: <span class="s">"明知故犯"</span>,<br>'
          '<span class="k">"platform"</span>: <span class="s">"netease:song"</span>,<br>'
          '<span class="k">"music"</span>: { <span class="k">"artist"</span>: <span class="s">"Max李玄"</span>, <span class="k">"album"</span>: <span class="s">"失温"</span> },<br>'
          '<span class="k">"audio"</span>: { <span class="k">"codec"</span>: <span class="s">"flac"</span>, <span class="k">"sampleRate"</span>: <span class="n">96000</span>, <span class="k">"bitsPerSample"</span>: <span class="n">24</span> },<br>'
          '<span class="k">"files"</span>: [{ <span class="k">"relativePath"</span>: <span class="s">"… .flac"</span>,<br>'
          '&nbsp;&nbsp;<span class="k">"sha256"</span>: <span class="s">"c2b9b112b352bd7f…"</span>,<br>'
          '&nbsp;&nbsp;<span class="k">"signature"</span>: <span class="s">"flac"</span> }]'
          '</div>'),
    slide(6, "DaVinci Resolve", "Straight into<br>your media pool.",
          "One click. Music lands by album, with source and checksums as clip metadata.",
          '<div class="panel tree">'
          '<div>📁 Master › <b>Sooogood</b> › Music › 失温</div>'
          '<div style="margin:6px 0 14px 48px">🎵 Max李玄 - 明知故犯 [3342319503].mp3</div>'
          '<div class="row"><span>Sooogood Artist</span><span>Max李玄</span></div>'
          '<div class="row"><span>Sooogood Album</span><span>失温</span></div>'
          '<div class="row"><span>Sooogood Audio Quality</span><span>MP3 · 44.1 kHz · 320 kbps</span></div>'
          '<div class="row"><span>Sooogood SHA-256</span><span>47dc10d3e83ee98d…</span></div>'
          '</div>'),
    slide(7, "Toolbox", "Built for<br>editors.",
          "ProRes & DNxHR proxies, HEVC, WAV, GIF and on-device transcription.",
          shot("toolbox", x=0, y=75, zoom=1.15)),
    slide(8, "AI agents · MCP", "Let your agent<br>drive it.",
          "Claude Code, Hermes and others can analyze, queue and send to Resolve. Never delete.",
          '<div class="panel">'
          '<span class="p">$</span> claude mcp add sooogood -- …/sooogood-mcp<br><br>'
          '<span class="c">→ analyze_music("…/song?id=3342319503")</span><br>'
          '{ <span class="k">"title"</span>: <span class="s">"明知故犯"</span>,<br>'
          '&nbsp;&nbsp;<span class="k">"best_quality"</span>: <span class="s">"Hi-Res"</span>,<br>'
          '&nbsp;&nbsp;<span class="k">"qualities"</span>: [<span class="s">"Standard 128k"</span>, …, <span class="s">"Lossless"</span>, <span class="s">"Hi-Res"</span>] }<br><br>'
          '<span class="c">→ enqueue_music · send_to_resolve · list_tasks …</span>'
          '</div>'),
    slide(9, "Free · GPL-3.0 · macOS 14+", "Six languages.<br>Zero tracking.",
          "Local-first, no telemetry, no ads, no DRM circumvention. Only save what you have the right to keep.",
          '<div class="pills" style="margin-top:40px">'
          + "".join(f'<div class="pill">{l}</div>' for l in ["English", "Français", "Deutsch", "日本語", "한국어", "中文"])
          + '</div><div class="facts" style="bottom:130px">'
          '<div class="fact"><b>Open source</b><span>Search “Sooogood Video Catch” on GitHub</span></div>'
          '<div class="fact"><b>Homebrew engines</b><span>yt-dlp · FFmpeg · deno</span></div>'
          '</div>'),
]


def main(out: pathlib.Path):
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for i, body in enumerate(SLIDES, 1):
            source = pathlib.Path(tmp) / f"{i:02d}.html"
            source.write_text(f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head>'
                              f'<body>{body}</body></html>', encoding="utf-8")
            big = pathlib.Path(tmp) / f"{i:02d}@2x.png"
            subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                            "--force-device-scale-factor=2", "--window-size=1080,1080", f"--screenshot={big}",
                            source.as_uri()], check=True, capture_output=True)
            target = out / f"{i:02d}.png"
            subprocess.run(["sips", "-z", "1080", "1080", str(big), "--out", str(target)], check=True, capture_output=True)
            print(target)


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "dist" / "promo")
