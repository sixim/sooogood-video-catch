# Sooogood Video Catch

[English](../README.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · **한국어** · [中文](README.zh-Hans.md)

크리에이터를 위한 로컬 우선 macOS 앱. 플랫폼이 실제로 제공하는 최고의 미디어 스트림을 저장하고, 음악은 태그·커버·가사를 담아 원본 음질로 다운로드하며, 모든 결과물을 검증 가능한 패키지(파일마다 SHA-256 매니페스트)로 DaVinci Resolve에 넘깁니다.

![홈](images/home.png)

## 주요 기능

- **동영상** — YouTube, Vimeo, Bilibili, Youku, HLS / DASH, 그리고 [yt-dlp](https://github.com/yt-dlp/yt-dlp)가 지원하는 약 1,700개 사이트. 형식 검사기로 다운로드 전에 모든 스트림(해상도, fps, 코덱, 비트레이트, 크기)을 보여 줍니다. 최고 화질 모드는 최고 영상과 오디오를 다시 인코딩하지 않고 합칩니다.
- **음악 다운로드** — NetEase Cloud Music과 QQ 뮤직의 싱글, 앨범, 재생목록, 아티스트, 차트. 음질은 내 계정을 따릅니다(회원은 무손실 / Hi-Res까지). 태그·커버·가사를 파일에 기록하고, 다운로드 후 실제 음질을 측정하며, 이미 가진 곡은 찾아서 건너뜁니다.
- **검증 가능한 패키지** — 다운로드마다 별도 폴더와, 출처·형식·도구 버전·파일별 SHA-256을 담은 `manifest.json`을 만듭니다.
- **DaVinci Resolve** — 클릭 한 번으로 패키지를 현재 프로젝트의 미디어 풀로 가져오며(음악은 *Sooogood › 음악 › 앨범*), 출처, 아티스트, 앨범, 실측 음질, 체크섬을 클립 메타데이터로 기록합니다.
- **도구 상자** — 하드웨어 ProRes Proxy / LT / 422, DNxHR, H.264 프록시, HEVC, 무손실 오디오 추출, WAV, GIF, 로컬 whisper.cpp 받아쓰기.
- **강좌와 재생목록** — YouTube 재생목록, Udemy와 Bilibili 강좌를 챕터별로 펼칩니다. DRM으로 보호된 강의는 건너뜁니다.
- **토렌트** — 마그넷 링크와 `.torrent` 파일을 로컬 전용 Transmission 엔진으로. 파일 선택, 순차 다운로드, 시딩 제한을 지원합니다.
- **AI 에이전트(MCP)** — `sooogood-mcp`로 Claude Code, Hermes 등 에이전트가 분석, 대기열 추가, 확인, Resolve 전송을 할 수 있습니다. 삭제 기능은 제공하지 않습니다.
- **다음으로 이동…** — 완료된 패키지를 다른 폴더나 디스크로 옮깁니다. 디스크 간 복사는 원본을 지우기 전에 매니페스트로 검증합니다.
- **6개 언어** — English, Français, Deutsch, 日本語, 한국어, 中文.

| 동영상 분석 | 음악 다운로드 |
|---|---|
| ![동영상](images/video.png) | ![음악](images/music.png) |

| 다운로드 작업 | 도구 상자 |
|---|---|
| ![다운로드](images/downloads.png) | ![도구 상자](images/toolbox.png) |

*스크린샷은 영어 화면입니다. 앱은 macOS 언어 또는 설정 › Language · 语言에서 고른 언어로 표시됩니다.*

## 홍보 자료

SNS 게시용 1080×1080 이미지 9장(3×3 그리드, 순서대로, 영어). 파일: [promo](promo/) · `python3 Scripts/build_promo.py`로 다시 생성.

| | | |
|---|---|---|
| <img src="promo/01.png" width="260"> | <img src="promo/02.png" width="260"> | <img src="promo/03.png" width="260"> |
| <img src="promo/04.png" width="260"> | <img src="promo/05.png" width="260"> | <img src="promo/06.png" width="260"> |
| <img src="promo/07.png" width="260"> | <img src="promo/08.png" width="260"> | <img src="promo/09.png" width="260"> |

## 요구 사항

- macOS 14 Sonoma 이상
- 명령줄 엔진은 [Homebrew](https://brew.sh)로 설치합니다(앱이 직접 실행 파일을 다운로드하지 않습니다):

```bash
brew install yt-dlp ffmpeg deno
```

선택 사항, 해당 기능에만 필요:

```bash
brew install transmission-cli whisper-cpp
```

## 빌드와 실행

```bash
git clone https://github.com/sixim/sooogood-video-catch.git
cd sooogood-video-catch
./Scripts/package_app.sh
open "dist/Sooogood Video Catch.app"
```

개발: `swift run MediaFetch`. 테스트: `swift test`.

AI 에이전트 연결(정확한 경로는 *설정 › AI Agent*에도 표시됩니다):

```bash
claude mcp add sooogood -- "/path/to/Sooogood Video Catch.app/Contents/MacOS/sooogood-mcp"
```

## 로그인과 개인정보

- 사이트 로그인은 플랫폼마다 독립된 앱 내 WebKit 창에서 하거나, 고른 브라우저의 세션을 재사용합니다. 쿠키는 로컬 엔진용 비공개 임시 파일로만 내보낸 뒤 삭제하며, 기록과 매니페스트에는 쿠키 데이터가 없습니다.
- Spotify는 공식 OAuth(PKCE)로 곡 식별 정보와 순서에만 쓰며, 토큰은 macOS 키체인에 보관합니다. Spotify 오디오는 다운로드하지 않습니다.
- 원격 측정, 광고, 추적이 없습니다. Sooogood 서버로 아무것도 보내지 않습니다.

## 의도된 제한

- DRM을 우회하지 않습니다(Netflix 콘텐츠, 보호된 Spotify 오디오, DRM 강의는 거부하거나 건너뜀).
- 음악 음질은 내 계정에 따라 다릅니다. 플랫폼에 권리가 없는 곡은 그렇게 표시하며, 지역 제한도 우회하지 않습니다.
- QQ 뮤직은 QQ 번호 로그인으로 동작합니다. WeChat 로그인은 다운로드 엔진이 지원하지 않습니다.
- 사이트는 자주 바뀝니다. `brew upgrade yt-dlp`로 yt-dlp를 최신으로 유지하세요.

**권리를 가진 콘텐츠, 허가를 받은 콘텐츠, 또는 플랫폼이 저장을 명시적으로 허용한 콘텐츠만 다운로드하세요.**

## 라이선스

GPL-3.0 — [LICENSE](../LICENSE) 참조. 외부 엔진(yt-dlp, FFmpeg, deno, Transmission, whisper.cpp)은 포함하지 않으며 Homebrew로 따로 설치하고 각자의 라이선스를 따릅니다.

## 문서

- [아키텍처](../ARCHITECTURE.md) · [개발자 가이드(중국어)](DEVELOPMENT.zh-Hans.md) · [변경 기록](../CHANGELOG.md) · [브로슈어](brochure/Sooogood-Video-Catch-ko.pdf)

---

*Big Buck Bunny* 스크린샷 © Blender Foundation, [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).
