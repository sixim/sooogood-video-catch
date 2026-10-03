# Sooogood Video Catch

[English](../README.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · **中文**

为创作者设计、本地优先的 macOS 应用：保存平台实际提供的最高质量媒体流，以原始音质下载音乐并自动写入标签、封面和歌词，再把一切以可验证的素材包（每个文件附 SHA-256 清单）交给达芬奇。

![首页](images/home.png)

## 功能亮点

- **视频** —— YouTube、Vimeo、哔哩哔哩、优酷、HLS / DASH，以及 [yt-dlp](https://github.com/yt-dlp/yt-dlp) 支持的约 1,700 个网站。下载前用格式检查器查看每条流（分辨率、帧率、编码、码率、大小）；「最高画质」模式把最佳视频和音频无损合并，不重新编码。
- **音乐下载** —— 网易云音乐、QQ 音乐的单曲、专辑、歌单、歌手和排行榜。音质取决于你自己的账号（会员可到无损 / Hi-Res）。自动写入标签、封面和歌词，下载后实测真实音质，本地已有的歌会识别并跳过。
- **可验证素材包** —— 每次下载一个独立文件夹，`manifest.json` 记录来源、格式、工具版本和每个文件的 SHA-256。
- **达芬奇对接** —— 一键导入当前项目的媒体池（音乐进入「Sooogood › 音乐 › 专辑」），来源、歌手、专辑、实测音质和校验值写入片段元数据。
- **创作者工具箱** —— 硬件 ProRes Proxy / LT / 422、DNxHR、H.264 代理、HEVC、无损抽音轨、WAV、GIF，以及本机 whisper.cpp 转录。
- **课程与播放列表** —— YouTube 播放列表、Udemy、B 站课堂按章节展开；受 DRM 保护的课时自动跳过。
- **Torrent** —— 磁力链接和 `.torrent` 文件由本机私有的 Transmission 引擎下载，支持选文件、顺序下载和做种限制。
- **AI agent（MCP）** —— `sooogood-mcp` 让 Claude Code、Hermes 等 agent 解析、入队、查询并发送到达芬奇；不开放任何删除操作。
- **移动到…** —— 把已完成的素材包移到别的文件夹或磁盘；跨磁盘时先复制并按清单校验，通过后才删除原件。
- **6 种语言** —— English、Français、Deutsch、日本語、한국어、中文。

| 视频解析 | 音乐下载 |
|---|---|
| ![视频](images/video.png) | ![音乐](images/music.png) |

| 下载任务 | 工具箱 |
|---|---|
| ![下载任务](images/downloads.png) | ![工具箱](images/toolbox.png) |

*截图为英文界面；应用跟随 macOS 语言，也可在「设置 › Language · 语言」中切换。*

## 宣发素材

9 张 1080×1080 英文宣传图，按顺序正好组成朋友圈 / 社交平台九宫格。文件在 [promo](promo/)，用 `python3 Scripts/build_promo.py` 重新生成。

| | | |
|---|---|---|
| <img src="promo/01.png" width="260"> | <img src="promo/02.png" width="260"> | <img src="promo/03.png" width="260"> |
| <img src="promo/04.png" width="260"> | <img src="promo/05.png" width="260"> | <img src="promo/06.png" width="260"> |
| <img src="promo/07.png" width="260"> | <img src="promo/08.png" width="260"> | <img src="promo/09.png" width="260"> |

## 运行环境

- macOS 14 Sonoma 或更新版本
- 命令行引擎通过 [Homebrew](https://brew.sh) 安装（应用不会自行下载可执行文件）：

```bash
brew install yt-dlp ffmpeg deno
```

可选，只在使用对应功能时需要：

```bash
brew install transmission-cli whisper-cpp
```

## 编译与运行

```bash
./Scripts/package_app.sh
open "dist/Sooogood Video Catch.app"
```

开发运行：`swift run MediaFetch`。测试：`swift test`。

接入 AI agent（准确路径也显示在「设置 › AI Agent」）：

```bash
claude mcp add sooogood -- "/path/to/Sooogood Video Catch.app/Contents/MacOS/sooogood-mcp"
```

## 登录与隐私

- 网站登录在每个平台独立的应用内 WebKit 窗口中完成，或复用你指定浏览器的登录态。Cookie 只导出到供本机引擎使用的私有临时文件，用完即删；任务历史和清单不含任何 Cookie。
- Spotify 通过官方 OAuth（PKCE）只读取曲目身份和顺序，令牌保存在 macOS 钥匙串；不会下载 Spotify 音频。
- 没有遥测、广告或跟踪，不向任何 Sooogood 服务器上传内容。

## 有意为之的边界

- 不绕过 DRM（Netflix 正片、受保护的 Spotify 音频、DRM 课时会被拒绝或跳过）。
- 音乐音质取决于你的账号。平台没有版权的歌会明确标出，也不绕过地区限制。
- QQ 音乐需要用 QQ 号登录；下载引擎不支持微信登录。
- 网站经常变化，请用 `brew upgrade yt-dlp` 保持 yt-dlp 为最新。

**仅下载你拥有权利、已获许可，或平台明确允许保存的内容。**

## 许可证

GPL-3.0，见 [LICENSE](../LICENSE)。外部引擎（yt-dlp、FFmpeg、deno、Transmission、whisper.cpp）不随应用分发，通过 Homebrew 单独安装，遵循各自的许可证。

## 文档

- [架构说明](../ARCHITECTURE.md) · [开发者指南](DEVELOPMENT.zh-Hans.md) · [更新记录](../CHANGELOG.md) · [宣传册](brochure/Sooogood-Video-Catch-zh-Hans.pdf)

---

*Big Buck Bunny* 截图 © Blender Foundation，[CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)。
