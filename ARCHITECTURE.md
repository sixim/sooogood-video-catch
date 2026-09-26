# Sooogood Video Catch 模块化与升级维护说明

## 依赖方向

```text
Sooogood Video Catch（SwiftUI App 组合层；内部 target 保留为 MediaFetch）
├── MediaFetchVideo（视频队列与下载引擎适配）
│   └── MediaFetchCore（领域模型、平台策略、manifest、历史）
├── MediaFetchMusic（Spotify OAuth/API、扫描、匹配、素材桥接）
│   └── MediaFetchCore
├── MediaFetchTorrent（仅 Local：Transmission 守护进程、RPC、做种策略、torrent 清单）
│   └── MediaFetchCore
├── MediaFetchResolve（仅 Local：DaVinci Resolve 官方脚本 API 桥接）
│   └── MediaFetchCore
├── MediaFetchTools（仅 Local：ffmpeg / whisper.cpp 工具箱）
│   └── MediaFetchCore
└── MediaFetchControl（仅 Local：控制协议、Unix socket、MCP 会话）
    └── MediaFetchCore
sooogood-mcp（可执行文件，stdio MCP → 应用控制端口）
└── MediaFetchControl
```

依赖只向下：Core 不依赖 SwiftUI、AppKit 或网络；Video 和 Music 可以单独编译、单独测试；`MediaFetch` 只负责页面、导航和依赖注入。新增平台或替换服务时，优先在对应模块添加适配器，不把平台判断散落到页面代码中。

## 稳定边界

- `MediaFetchCore`：`DownloadJob`、`MediaMetadata`、`DownloadProfile`、平台识别、URL 校验、SHA-256 和 manifest schema。这里的 schema 变更必须增加版本，不改写既有 v1/v2 文件。
- `SecurityScopedBookmarkStore`：保存用户明确选择的目录 bookmark，并在 Store profile 重新启动时恢复访问；不保存媒体内容。持有 scope 的对象必须在生命周期结束时调用 `stopAccessing`。
- `MediaFetchVideo` 的纯决策层：`YtDLPArgumentBuilder`（参数）、`RetryPolicy`（是否重试、如何调整）不启动进程，直接用真实 stderr 片段做单元测试；`EngineDiagnostics`、`MediaSignature`、`EngineVersion` 位于 Core。新的失败类型先加诊断和测试，再改 UI。
- `MediaFetchVideo`：`DownloaderService` 是当前 UI 的 façade；`VideoToolchain` 集中描述 yt-dlp/FFmpeg 的来源、环境和 Cookie 能力。Local profile 发现本机工具；Store profile 的视频 toolchain 固定为空，视频入口只渲染说明页。
- `MediaFetchMusic`：Local profile 使用 ffprobe 获取更完整的容器/编码标签；Store profile 使用 `NativeAudioScanner` + AVFoundation，不嵌入或启动第三方 helper。`LocalAudioScanner` 的完整 Process/ffprobe 实现以编译条件排除在 Store 二进制之外；未来替换原生探针或增加合规的标签服务时，不需要改写 Spotify UI 和匹配规则。
- Store profile 即使保留跨 profile 的公开工厂方法，也只编译 `AudioToolchain`/`VideoToolchain` 的无工具原生 stub，并将 PATH 固定为系统安全路径；Local profile 的 Homebrew 路径不会进入 Store 的可执行逻辑。
- `MediaFetchMusic`：Spotify 的 OAuth、API 分页、24 小时元数据缓存、本地扫描、匹配规则和逐字节复制都在这里。`AudioToolchain` 集中描述 ffprobe 的来源；音频来源通过 `AudioSource` 建模，Spotify 音频地址在服务层拒绝。
- `SpotifyDemoFixture`：音乐模块内的合成元数据夹具，供 Store 审核演示和 UI 截图使用；不包含网络请求、凭据、封面字节或音频字节。
- `MediaFetch`：SwiftUI 状态与导航。ViewModel 通过公开接口消费模块，不直接解析 JSON 或操作 Keychain。
- `StreamingSiteLoginConfiguration`：Core 中的非敏感登录偏好模型，记录平台、方式、兼容浏览器与显式启用状态；旧数据缺少方式时仍按外部浏览器解释。`SiteSessionCookies` 只负责域名隔离与 Netscape Cookie 编码。
- `InAppSiteSession`：App 层的 WebKit 会话生命周期与 HTTPS 导航策略，每个平台稳定的独立 WKWebsiteDataStore 标识不可随意更改；清除会话时关闭读取并删除该平台全部 WebKit 数据。Google 内嵌登录明确不可用，不注入脚本或伪装 UA。
- `StreamingSiteLoginStore`：组合层持久化非敏感偏好，并通过异步会话 provider 注入 `DownloaderService`。Video 模块不依赖 WebKit；`TemporaryCookieFile` 管理权限受限的临时引擎文件，直到进程结束才释放。重启恢复任务只记住会话方式，需要当前配置仍启用才能导出凭据。Store profile 编译排除 WebKit 登录与 provider。
- Debug 预览使用固定 Spotify 场景和不可交互的宿主；预览初始化关闭 UserDefaults、bookmark、Keychain、网络和文件写入，避免 UI 验收污染开发者状态。

- `MediaFetchTorrent`：`TransmissionDaemon` 管理私有子进程（只监听 loopback、随机端口、每次启动新凭据），`TransmissionRPCClient` 只使用 4.1 的 snake_case JSON-RPC 2.0；`TorrentService` 是 UI façade，种子的续传状态由引擎自己保存在配置目录，应用只在 `torrent-history.json` 里记录策略和清单路径。整个模块以 `#if !MEDIAFETCH_STORE_PROFILE` 包裹，Store 预检会强制检查。
- `MediaFetchResolve`：`ResolveImportPlanner` 是纯函数（素材包 → 导入请求，读取 manifest 里的来源信息）；`ResolveBridge` 用内嵌 Python 脚本调用 `DaVinciResolveScript`，请求经 stdin 传入、JSON 从 stdout 返回；`ResolveService` 是 UI façade，并负责写 `resolve-imports.json`。测试用假的 `DaVinciResolveScript` 模块驱动真实的 Python 脚本；设置 `MF_LIVE_RESOLVE=1` 可以对真实达芬奇做只读连接测试。
- `MediaFetchTools`：`FFmpegCommandBuilder`（纯函数，负责预设 → 参数）、`ToolEngine`（探测、执行、转录）、`ToolService`（单并发队列，因为 ffmpeg 和 whisper 都会占满机器）。衍生文件记录 `DerivativeLog` 放在 Core，所以达芬奇模块不依赖工具箱也能读到代理关系。
- `MediaFetchControl`：`ControlTool.all` 是工具清单的唯一来源，应用和 helper 共用；`ControlServer` / `ControlClient` 使用按行分隔的 JSON，走 0600 Unix socket，并用 `getpeereid` 校验调用方是同一用户；`MCPSession` 是可单测的纯协议层。应用侧的 `AgentControlBridge` 只调用现有服务，不另写一套业务逻辑；路径限制集中在 `AgentPaths`。新增工具时先改 `ControlTool.all`，再在 bridge 里实现，并在测试里确认仍然没有删除类工具。
- Local 专属模块（Torrent，以及后续的 MCP、工具箱）每个源文件都必须带编译边界，App 层的入口也放在同样的条件编译里。

## 版本与迁移策略

1. 版本号和 build 号以 `MediaFetchCore/ReleaseInfo.swift` 为单一运行时来源；`Resources/Info.plist` 与 `Resources/Info-Store.plist` 是打包所需的声明副本，由 `validate_store_submission.sh` 阻止漂移。
2. 修改持久化模型时保留旧 decoder，增加显式迁移测试；视频历史和 Spotify 历史永远分离。
3. 平台 API 变更只更新适配器和契约测试；UI 使用稳定的领域模型，不依赖 Spotify 原始 DTO。
4. 新增需要浏览器登录的平台时，只在 `StreamingPlatform.browserLoginPlatforms` 注册官方 HTTPS 入口和用途说明；视频页通过 URL 到 Cookie source 的映射消费配置，不增加平台特例或复制登录状态。
5. 每次发布必须执行 `swift test`、`./Scripts/validate_store_submission.sh`、`./Scripts/validate_store_metadata.sh`、`./Scripts/package_app.sh`、`codesign --verify --deep --strict`，并保存 Xcode/SDK 版本、构建 hash 和版本信息；真正上传前还要设置 `REQUIRE_STORE_SCREENSHOTS=1 REQUIRE_PUBLIC_WEB=1`，强制启用真实截图和公开网页检查。Local/Store 打包使用独立 SwiftPM scratch path，避免条件编译产物串 profile。应用 bundle 先在 staging 目录完成资源复制、签名和验证，再原子替换 `dist/Sooogood Video Catch.app`，签名失败不会破坏现有包。
6. 日常升级优先运行 `Scripts/verify_release.sh`，它集中执行两种 profile 测试、Shell/VI/商店文案审计和 Store 预检；设置 `REQUIRE_RELEASE_ARTIFACTS=1` 后再强制要求真实截图、公网页面和已验签 `.pkg`，避免只通过源码检查就误报可发布。

## App Store 适配边界

Mac App Store 版本使用 `Resources/MediaFetch-Store.entitlements` 的 App Sandbox 配置，用户目录只通过选择器授予权限，凭据仍放在 Keychain。当前本地开发版仍支持 Homebrew 的 `/opt/homebrew/bin/yt-dlp`、`ffmpeg` 以及浏览器 Cookie；这些路径和跨应用 Cookie 读取不能直接带入沙盒商店版。

因此保留两种可替换实现：

- Local profile：本机工具发现，适合内测和专业工作流。
- Store profile：使用系统 AVFoundation 读取本地音频 metadata，不嵌入第三方可执行文件；第三方站点视频下载在商店版编译为明确的说明页。本地完整版保留独立下载工作流，两个 profile 共用 Core 和 UI 状态边界。

发布脚本在写入 `dist/Sooogood Video Catch.app` 之前校验 profile、签名身份和 provisioning profile；Store 使用 `Info-Store.plist` 的音乐分类，Local 使用视频分类。Store 默认不包含嵌套 helper，这样签名缺失时不会留下一个看似可发布的半成品 bundle。

在没有完成真实签名、沙盒下的用户选择目录、原生 AVFoundation 扫描和回归测试前，不把 Store profile 宣称为“可提交”。由于 Apple 5.2.3 的第三方媒体下载限制，完整视频下载能力只作为 Local profile，不应误带进 Store profile。
