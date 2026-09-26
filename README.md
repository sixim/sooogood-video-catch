# Sooogood Video Catch

Sooogood Video Catch 是一个面向 macOS 的本地媒体工具。视频页用 `yt-dlp` 解析平台实际提供的媒体流，用 `FFmpeg` 做必要的无损封装；音乐页用 Spotify 曲目身份和顺序整理用户自己拥有的本地或 DRM-free 音频。

当前本机 yt-dlp 版本提供约 1,752 个提取器，并保留通用网页、HLS 与 DASH 解析能力。网站会持续变化，列入提取器不等于永久可用，最终以应用对具体链接的实时解析结果为准。

## 当前能力

- 电影感深色首页，分别进入“视频”“音乐”“下载任务”和“设置”
- 解析单条 YouTube、Vimeo 或其他 `yt-dlp` 支持网站的链接
- 显示标题、作者、时长与检测到的最高分辨率
- 最高画质：最佳视频流 + 最佳音频流，无损合并为 MKV
- 原始流：分别保存平台直接提供的视频与音频文件
- 兼容 MP4：优先使用 H.264 + M4A，无损封装为剪辑软件更易接受的 MP4
- 下载进度、速度、预计剩余时间、取消和完成文件定位
- 参数以数组形式传给下载引擎，不经过 shell
- Vimeo 登录可见内容可由用户明确启用 Safari、Chrome 或 Firefox 登录状态
- 多链接下载队列、持久化任务历史与中断后手动继续
- 下载前格式检查器：格式 ID、分辨率、FPS、容器、编码、HDR、语言、码率与大小
- 每条媒体建立独立素材包，选择性保存缩略图、平台 info.json、中英文人工字幕与自动字幕
- 下载完成后对素材包内每个文件计算 SHA-256，并生成 `manifest.json`
- 明确识别 YouTube、Vimeo、哔哩哔哩、优酷和通用 HLS/DASH，并继续尝试 yt-dlp 的其他提取器
- 为非 DRM 来源提供“仅保存最佳原始音频”模式，不转换 MP3、不伪装来源
- Spotify 独立音乐页：通过官方 OAuth PKCE 读取单曲、专辑与自有/协作歌单的身份和曲序
- Store 版音乐页提供“查看演示”入口，使用合成元数据展示审核流程，不需要 Spotify 凭据或网络
- 只读扫描本地音乐资料夹，按 ISRC、歌手、标题、专辑与时长进行严格匹配；歧义版本必须人工确认
- 把已确认的本地或授权 DRM-free 音频逐字节复制为 `audio/` 素材包，并生成 `playlist.m3u8` 与 schema v2 `manifest.json`
- 在视频解析前阻止 Netflix 与 Spotify 受保护音频链接，避免把预告片或其他平台替代音频误报为原文件
- 下载失败自动重试（429 退避、YouTube 备用客户端、IPv4、去字幕），失败原因显示为「原因 + 一个按钮」，可展开查看脱敏后的实际命令
- YouTube 使用分片 DASH + 8 路并发（实测比 yt-dlp 默认快 15–25%），支持暂停/继续，下载期间阻止闲置睡眠
- 首页统一输入框：视频链接、磁力链接、.torrent、本地媒体一框识别；批量预检（需登录 / 已下载 / 磁盘空间）；可选 ⌘⇧D 全局快捷键
- 课程与播放列表：YouTube 播放列表、Udemy、B 站课堂按章节展开，下载到「课程/章节/课时」结构并生成 `collection-manifest.json`；DRM 课时跳过
- Torrent（Local 版）：私有 transmission-daemon 引擎，选文件、顺序下载、做种策略，完成后生成带 SHA-256 的 `torrent-manifest.json`
- 创作者工具箱（Local 版）：硬件 ProRes Proxy/LT/422、DNxHR、H.264 代理、HEVC、无损音轨、WAV、GIF、whisper.cpp 本机转录，结果记入 `derivatives.json`
- DaVinci Resolve 对接（Local 版）：一键把素材包导入当前项目媒体池，写入来源与 SHA-256 元数据，自动关联代理、导入字幕，可选建时间线
- MCP server（Local 版）：`sooogood-mcp` 让 Claude Code、Hermes 等 agent 查询、下载、运行工具箱、发送到达芬奇；不提供删除操作

## 环境

遵循本机统一标准，CLI 依赖通过 Homebrew 安装：

```bash
brew install yt-dlp ffmpeg deno
```

可选（对应功能才需要）：

```bash
brew install transmission-cli whisper-cpp
```

接入 Claude Code（打包后在「设置 › AI Agent」里可一键复制路径）：

```bash
claude mcp add sooogood -- "/path/to/Sooogood Video Catch.app/Contents/MacOS/sooogood-mcp"
```

开发运行：

```bash
swift run MediaFetch
```

打包成标准 macOS 应用（输出到 `dist/Sooogood Video Catch.app`）：

```bash
./Scripts/package_app.sh
open "dist/Sooogood Video Catch.app"
```

测试：

```bash
swift test
```

## 模块化与后续维护

源码按职责拆分为独立 target：`MediaFetchCore`（领域模型与 manifest）、`MediaFetchVideo`（视频引擎适配）、`MediaFetchMusic`（Spotify 与音频匹配）、仅 Local 版的 `MediaFetchTorrent`、`MediaFetchTools`、`MediaFetchResolve`、`MediaFetchControl` 与 `sooogood-mcp`，以及 `MediaFetch`（SwiftUI 组合层）。依赖方向和迁移约定见 [ARCHITECTURE.md](ARCHITECTURE.md)。

本地内测打包：

```bash
./Scripts/package_app.sh
```

日常升级或准备 release 时，可用 `Scripts/verify_release.sh` 一次运行 Local/Store 两套测试、Shell/VI/商店文案审计和 Store bundle 预检；真实上传前再加上 `REQUIRE_RELEASE_ARTIFACTS=1`，把截图、公网页面和签名 `.pkg` 升级为硬门槛。

```bash
./Scripts/verify_release.sh
REQUIRE_RELEASE_ARTIFACTS=1 ./Scripts/verify_release.sh
```

商店配置只在具备 Mac App Distribution 证书和 Store provisioning profile 后启用：

```bash
CODESIGN_IDENTITY="Apple Distribution: Your Team" \
PROVISIONING_PROFILE="/path/to/MediaFetch.provisionprofile" \
BUILD_PROFILE=store ./Scripts/package_app.sh
```

Store profile 会启用 App Sandbox、网络和用户选择目录权限，使用音乐分类的 `Info-Store.plist`，并编译 AppIcon 与隐私清单；商店版明确不提供第三方站点视频下载、不执行 `yt-dlp`/`ffmpeg`，使用 AVFoundation 原生读取本地音频元数据，不嵌入第三方 helper。完整视频下载仍属于 Local profile；在真实签名包上完成沙盒目录授权、Spotify OAuth 和文件扫描回归前，不能把本机内测包当作可提交版本。

完整的商店待办、签名前置条件和升级门槛见 [STORE_SUBMISSION.md](STORE_SUBMISSION.md)。
具备证书、provisioning profile、真实 Store 截图和已部署的 HTTPS 页面后，使用 `Scripts/build_store_pkg.sh` 生成并校验签名 `.pkg`。
该脚本会先强制运行截图/公网页面预检，再在独立 staging 目录生成并验签，最后原子替换 `dist/SooogoodVideoCatch.pkg`；输出文件名必须以 `.pkg` 结尾且不含空格。
解锁 macOS 并从最终签名 Store bundle 采集五张截图后，运行 `Scripts/validate_store_screenshots.sh StoreAssets/Screenshots` 验证 PNG 尺寸、无 alpha 通道和 SHA-256；封面图不能替代真实应用截图。修改商店文案后运行 `Scripts/validate_store_metadata.sh`，自动检查名称、副标题、推广文案、描述和关键词的 App Store Connect 限制。真正上传前运行 `REQUIRE_STORE_SCREENSHOTS=1 REQUIRE_PUBLIC_WEB=1 ./Scripts/validate_store_submission.sh "dist/Sooogood Video Catch.app"`，把截图和网页占位符检查升级为硬门槛。
修改 Logo、AppIcon 或封面后运行 `Scripts/validate_brand_assets.sh`，逐项检查源稿、10 个图标尺寸、Store/Local 封面和双语封面说明。
隐私政策和支持页的可部署 HTML 模板位于 `StoreAssets/Web/`；发布前必须替换占位符并部署到自己的 HTTPS 域名。

## “原始文件”的准确含义

流媒体网站通常不会公开上传者最初上传的母版文件。Sooogood Video Catch 能保存的是平台当前向该账户/地区/设备提供的最高质量编码流：

- “保留平台原始音视频流”不会转码，但视频和音频通常是两个文件。
- “最高画质”同样不转码，只用 FFmpeg 把最佳视频和音频重新封装到一个 MKV 容器。
- 分辨率相同不代表编码码率、色深、HDR 或音轨一定相同，最终以解析出的格式为准。

## 素材包与审计清单

每条媒体保存到一个独立目录。`manifest.json` 记录来源 URL、平台、媒体 ID、下载配置、实际格式、是否调用浏览器登录状态、Sooogood Video Catch/yt-dlp/FFmpeg 版本，以及素材包内每个文件的字节数和 SHA-256。它不会记录 Cookie 内容。

任务历史保存在：

```text
~/Library/Application Support/MediaFetch/history.json
```

应用异常退出时，正在下载或生成清单的任务会在下一次启动时显示为“已暂停”；由用户点击“继续队列”后恢复，应用不会在启动时自动读取浏览器 Cookie。

Spotify 音乐素材包历史单独保存在：

```text
~/Library/Application Support/MediaFetch/spotify-history.json
```

该文件只记录集合身份、素材包与 manifest 路径、保存数量和时间；不会迁移或改写视频历史及 manifest v1。

## 流媒体网站登录

本地版在“设置 → 流媒体网站登录”与视频页提供应用内登录入口。Vimeo、哔哩哔哩和优酷的官方 HTTPS 页面在独立 WebKit 窗口中打开；完成登录后点击“保存会话并返回”。各平台使用独立、持久化的网站数据存储，重启后可继续使用，可通过“清除会话”退出。检测到 Cookie 不代表账号已验证，最终以视频解析结果为准。

Sooogood Video Catch 不注入脚本或读取官网表单密码。应用内网站会话由 WebKit 保存在本机；只有用户明确启用后，才导出当前平台域名下的 Cookie 到临时私有目录（0700）内的文件（0600），供本机 yt-dlp 使用，操作结束或取消完成后删除。异常断电/强制终止可能留下系统临时目录中的文件。偏好、任务历史及 manifest 只记录会话方式，绝不记录 Cookie 字节。

YouTube 使用的 Google 登录不支持应用内嵌网页；应用明确显示该限制，不伪装浏览器。用户可主动选择“兼容登录”，在 Safari、Chrome 或 Firefox 完成登录后使用对应浏览器会话。Vimeo 的 Google 等第三方登录也可能需要该方式。兼容模式下引擎会读取所选浏览器的 Cookie 库，不会静默切换浏览器；旧版偏好保留原先的浏览器方式。规则参考：[Google OAuth policies](https://developers.google.com/identity/protocols/oauth2/policies)。

Vimeo 的网页客户端目前可能要求登录，即使链接本身可以在已登录浏览器中观看。浏览器中的账号还必须实际拥有该视频的访问权限；Cookie 不会绕过私有、付费或 DRM 访问控制。

macOS 会额外保护 Safari Cookie 数据。Sooogood Video Catch 会在解析前检查访问权限，并提供“打开完整磁盘访问”入口；不希望授予该权限时，推荐使用已经登录 Vimeo 的 Google Chrome。应用不会尝试绕过系统权限。

## Spotify 个人媒体桥接设置

1. 在 [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) 创建你自己的 App。
2. 为该 App 注册回调地址：`http://127.0.0.1/oauth/spotify/callback`。这里故意不写端口；Spotify 允许回环 IP 在授权请求中使用临时动态端口。
3. 在 Sooogood Video Catch 的“设置”页粘贴 Client ID。应用不需要、也不会保存 Client Secret。
4. 点击“连接 Spotify”，在浏览器中完成授权。Sooogood Video Catch 只申请 `playlist-read-private` 与 `playlist-read-collaborative`。
5. 回到“音乐”页载入 Spotify 单曲、专辑或歌单链接，选择本地音乐资料夹，审核匹配结果后保存素材包。

回调监听只绑定 `127.0.0.1`，登录令牌只写入 macOS 钥匙串。动态端口规则与 PKCE 流程可分别参阅 [Spotify Redirect URI](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri) 和 [Authorization Code with PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow) 官方说明。

## 平台能力边界

| 平台或来源 | 状态 | 说明 |
|---|---|---|
| YouTube | Local profile | 视频、独立音视频流、字幕、缩略图和元数据；商店版不提供第三方站点下载 |
| Vimeo | Local profile | 登录可见内容通常需要浏览器登录状态；商店版不读取浏览器 Cookie |
| 哔哩哔哩 | Local profile | 视频、番剧、音频、直播等由当前 yt-dlp 提取器处理；商店版不提供第三方站点下载 |
| 优酷 | Local profile | 公开内容可直接尝试；商店版不提供第三方站点下载 |
| HLS / DASH / 普通网页嵌入媒体 | 尝试解析 | 仅限服务器实际提供、未受 DRM 保护的流 |
| Netflix 正片 | 不支持 | 使用 DRM；不会绕过，也不会把网页预告片当成正片 |
| Spotify 音乐 | 个人媒体桥接 | Spotify 只提供曲目身份和曲序；音频必须来自用户拥有的本地文件或明确授权的 DRM-free HTTPS 直链 |
| Spotify 播客 | 使用公开来源 | 优先粘贴发布者公开 RSS 或直接音频链接 |

Spotify 页面不会下载 Spotify 音频、读取 Spotify Cookie、抓取客户端缓存、录制播放输出，或自动搜索 YouTube 等替代来源。OAuth access/refresh token 只保存在 macOS 钥匙串，Client ID 保存在本机设置；Spotify 元数据缓存最长 24 小时。

“全能”在本项目中指尽可能覆盖可合法获取的非 DRM 流，并为个人拥有的音乐建立可追溯素材包，而不是绕过 DRM、会员授权或付费访问控制。

## 使用边界

仅用于你拥有权利、已获许可或平台明确允许下载的内容。本项目不实现 DRM 绕过，也不承诺每个网站永久可用；网站更新后通常需要同步更新 `yt-dlp`。
