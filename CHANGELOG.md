# Changelog

## 0.16.0 (build 21) · 音乐下载 M3：音质核验

- 下载完成后用 ffprobe 测量文件的真实编码、采样率、位深和码率，判定实际音质档位，并和平台标称（所选格式的档位）对比；结果写入素材包清单（视频清单 schema 升级到 3，新增可选字段 `audio`、`musicQualityPreference`）。
- 音乐页和任务页显示实测音质（如「MP3 · 44.1 kHz · 320 kbps」）；实际低于平台标称时给出警告。
- 选择「只要无损」而账号拿不到无损时立即失败并说明原因，不再白白重试。实测免费账号 2.9 秒内给出提示。
- 实测：网易云 2 首，实测 320k MP3，与标称一致，清单已记录。

## 0.15.0 (build 20) · 音乐下载 M2：音乐下载页

- 新增「音乐下载」页（首页入口；粘贴网易云 / QQ 音乐链接或分享文案会自动打开这里）：支持单曲、专辑、歌单、歌手、排行榜。
- 单曲显示封面、歌手、专辑、时长、是否有歌词，以及**当前账号可下载的全部音质**（标准 128k / 较高 192k / 极高 320k / 无损 / Hi-Res）。
- 列表自动检测前 40 首的音质（每次 3 首），其余可一键「检测全部音质」；支持全选、单选、按专辑分组并整张选中；显示当前账号看不到的曲目数。
- 音质偏好：最高可用 / 只要无损 / 最高 320k。按所选偏好已知拿不到的曲目会明确列出并跳过，绝不用低音质冒充。
- 整理方式：歌手 / 专辑 / 歌曲、平铺、按歌单顺序。每首歌一个素材包：原始音频（不转码）+ 嵌入的标签和封面 + 封面文件 + `.lrc` 歌词 + `manifest.json`。
- 音乐任务复用现有下载队列（自动重试、诊断、阶段条、清单），页面底部显示最近的音乐任务，可直接发送到达芬奇。
- 实测（网易云，未登录）：解析出 3 档音质和歌词；热歌榜 200 首可展开；下载的 2 首各自得到 320k MP3、嵌入封面和标签、封面文件和歌词。
- 网易云偶尔会有单个请求卡到超时，音乐任务的网络超时缩短到 15 秒，最坏等待减半。
- 登录判断统一为 `StreamingSiteLoginStore.routing(for:)`，音乐页和 MCP 共用。

## 0.14.0 (build 19) · 音乐下载 M1：平台接入

- 新增平台「网易云音乐」「QQ 音乐」（下载经 yt-dlp 内置解析器），支持应用内登录与浏览器登录方式。
- 新增 `MusicLink`（Core，纯逻辑）：把各种分享链接规范成引擎接受的形式。
  - 网易云：`#/` 路由、`/m/` 移动版、`y.music.163.com`、我的歌单路径；单曲、专辑、歌手、歌单、排行榜、电台。
  - QQ 音乐：桌面 `ryqq`、旧版 `yqq/*.html`、`i.y.qq.com` 移动分享页（songmid / albummid / 歌单 id）。
- 短链（`163cn.tv`、`c6.y.qq.com/base/fcgi-bin/u`）自动展开为真实页面地址，只在音乐域名内跟随跳转，跳到其他域名一律拒绝。视频页会把短链原地替换成真实链接；MCP 调用同样适用。
- 链接提取改为在任意文本里查找：能直接粘贴 App 的分享文案（例如 `《晴天》https://…（来自@网易云音乐）`）。
- Cookie 隔离：网易云只导出 `music.163.com` 的会话；QQ 音乐的登录放在整个 `qq.com` 域，所以按名单只导出音乐会话 Cookie（`uin`、`qqmusic_key`、`fqm_pvqid` 等），QQ 账号身份 Cookie（`skey`、`p_skey` 等）不会交给下载引擎。
- 网易云 / QQ 的歌单、专辑、歌手、排行榜会出现「展开列表」；QQ「仅限注册用户」识别为需要登录。
- 修复：0.12 新增的 Udemy 应用内登录缺少会话存储编号，点击会导致应用崩溃。现在每个登录平台都有测试保证。

## 0.13.1 (build 18)

按计划做实机验证时发现并修复的问题：
- Torrent 磁力链接：Transmission 不会为暂停状态的磁力链接获取元数据，导致「先选择文件」永远等不到文件列表。现在磁力链接以 50 KB/s 限速启动，元数据一到就停下等你选择；确认后解除限速开始下载。实测 Debian ISO：5.3 秒拿到元数据，下载完成后按「完成即停」停止，清单已生成。
- Torrent：修复两处竞态：一是后台轮询可能抢先生成记录，丢掉「等待选择文件」状态；二是「停住等选择」的指令可能在你确认之后才生效，把刚开始的下载又停掉。
- 课程：课程里有付费课时时，yt-dlp 会以错误码退出，但目录其实已经输出了；现在只要目录可用就展开，并统计、提示无法观看的课时数量。「需要购买课程」识别为需要登录。
- 课程：完整解析出来的条目（B 站课堂试看课）改用课时页面链接，不再使用很快过期的 CDN 直链。
- 已验证：B 站课堂试看课展开 + 下载（2 个课时，`course-manifest.json` kind=course）；MCP 在应用未运行时自动拉起应用，`enqueue_download` → `get_task` 完成 → `read_manifest` 均通过；已用 `claude mcp add` 注册（本项目本地作用域），显示 ✔ Connected。

## 0.13.0 (build 17)

按原计划补齐遗漏项：
- 任务页改为按引擎分区（视频 / Torrent / 处理）；视频任务显示阶段条：解析 → 下载 → 合并 → 校验 → 清单，下载阶段附带速度和剩余时间。
- 首页统一入口收到课程或播放列表链接时，直接打开课时选择面板。
- Torrent：RPC 凭据存入登录钥匙串；新增「退出应用后继续做种」，重新打开应用时自动接管同一个后台引擎；设置页新增 Torrent 卡片（默认目录、监听端口、上下行限速）。
- MCP 新增 `list_torrents`。
- 课程（Udemy、B 站课堂，或任何带章节的列表）的清单改名为 `course-manifest.json`，播放列表仍为 `collection-manifest.json`。
- yt-dlp 过期提醒阈值改为 30 天，与计划一致。
- 达芬奇：未被选用的代理不会再被导入成独立片段；`.ogg` / `.opus` 等达芬奇读不了的音频会跳过；音轨是 Opus / Vorbis 时（达芬奇导入后没有声音）会提示用工具箱生成 WAV 或 ProRes 422。已在 DaVinci Resolve Studio 21.0.4 上实机验证。

## 0.12.1 (build 16)

- YouTube 下载改用分片 DASH（`youtube:formats=dashy`），让 8 路并发分片真正生效。2026-09-26 在 Mac Studio（Wi-Fi）上实测 1440p60（355 MB）：yt-dlp 默认 31.7–35.8 MB/s，本应用 38.7–40.9 MB/s，快 15–25%；16 路反而更慢，保持 8 路。解析阶段不启用，格式列表保持不变。
- 修复：应用崩溃、强制退出或被 kill 后，私有 transmission-daemon 会继续运行并做种。现在守护进程由一个 sh 看门狗托管，应用进程消失后会自动停止（已实测父进程 SIGKILL 后守护进程随之退出）。
- 新增只在显式开启时运行的实网基准测试 `LiveBenchmarkTests`（`MF_LIVE_NETWORK=1`）：4K 完整流程、工具箱、转录、Torrent。
- 实测结论（同一台机器）：4K60 最高画质下载 + 合并 + SHA-256 清单 23.9 秒（927 MB，全程 38.8 MB/s）；ProRes Proxy 2.9× 实时（瓶颈是 M1 Max 没有 AV1 硬件解码），H.264 代理 3.7×，无损提取音轨 422×；whisper small-q5_1 转录 20.7× 实时；Debian ISO 种子 756 MB 用时 64.5 秒（平均 11.7 MB/s，峰值 36 MB/s）。VideoToolbox 硬件解码在这台机器上比软件解码更慢（VP9 3.2× 对 7.0×），所以不启用。

## 0.12.0 (build 15)

- 新增课程与播放列表下载：视频页识别到 YouTube 播放列表（包括带 `list=` 的观看链接）、Udemy 课程、B 站课堂、B 站合集 / 收藏夹时，会出现「展开课程 / 播放列表」，按章节列出课时，可以整章或逐个选择。
- 选中的条目下载到同一个文件夹：`课程名/NN 章节名/NNN - 标题 [id]/`，每个课时依然是带 SHA-256 清单的素材包；课程根目录生成 `collection-manifest.json`，记录每一项是已完成、失败，还是因 DRM 被跳过。
- 新增 Udemy 平台，支持应用内 / 浏览器登录；Udemy 和 B 站课堂的请求始终放慢节奏，降低账号受限风险；有 DRM 保护的课时一律跳过，不做任何绕过。
- MCP 新增 `expand_collection`、`enqueue_collection`，agent 也能整课下载。

## 0.11.0 (build 14)

- 新增 MCP server（仅 Local 版）：打包进应用的 `sooogood-mcp`（stdio，JSON-RPC 2.0，支持协议版本 2025-06-18 / 2025-03-26 / 2024-11-05），让 Claude Code、Hermes 等 agent 调用本应用。
  - 15 个工具：`app_status`、`analyze_url`、`preflight_batch`、`enqueue_download`、`list_tasks`、`get_task`、`pause_task`、`resume_task`、`cancel_task`、`retry_task`、`read_manifest`、`add_torrent`、`run_tool`、`get_transcript`、`send_to_resolve`。**没有任何删除类工具。**
  - 应用内的本地控制端口（Unix socket，权限 0600，只接受当前用户的进程）；应用没开时 helper 会在后台自动启动它。
  - agent 走和界面完全相同的服务：受保护平台阻断、DRM 拒绝、登录方式、不覆盖文件、清单审计全部生效。agent 只能读写「下载」「影片」和你在应用里选择的文件夹；Torrent 必须先由你在应用内确认使用说明。
- 设置页新增「AI Agent（MCP）」卡片：开关（默认开启），以及可直接复制的 `claude mcp add …` 命令和通用 JSON 配置。
- 新模块 `MediaFetchControl`（协议、socket、MCP 会话，不依赖任何引擎模块）和可执行文件 `sooogood-mcp`；应用侧由 `AgentControlBridge` 实现。

## 0.10.0 (build 13)

- 新增创作者工具箱（仅 Local 版，独立模块 `MediaFetchTools`）：ProRes Proxy / LT / 422（VideoToolbox 硬件编码，不可用时自动退回软件 `prores_ks`）、DNxHR LB 代理、H.264 代理、HEVC 压缩、无损提取音轨、WAV 24-bit/48 kHz、GIF 预览，以及基于 whisper.cpp 的本机转录（输出 SRT / VTT / TXT）。
- 代理自动半分辨率（超过 1080p 时）；输出永远不覆盖已有文件；每个结果连同源文件和输出的 SHA-256、完整命令、耗时写入 `derivatives.json`，不改动原 manifest。
- 发送到达芬奇时自动把工具箱生成的代理关联到原片段（同一片段有多个代理时，优先顺序为 ProRes → DNxHR → H.264）。
- 转录模型：可从 Hugging Face 或 hf-mirror（国内）下载，下载前显示来源、大小和保存位置，并校验 ggml 文件头；也可以直接链接电脑上已有的模型文件，不复制。
- 任务页已完成项新增「处理…」，首页新增「工具箱」入口，拖入本地媒体文件会自动进入工具箱；每个任务显示耗时和「N× 实时」速度。
- 设置页「本机工具」新增 whisper.cpp 状态。

## 0.9.0 (build 12)

- 首页新增统一输入框：粘贴或拖入视频链接、磁力链接、.torrent 或本地媒体文件，自动识别并打开对应页面（`InputClassifier`，纯逻辑，位于 Core）。Finder 打开 .torrent 和系统里的 magnet 链接也走同一套路由。
- 视频页新增「先预检 N 条链接」：每次解析 3 条，汇总不支持、需要登录、不存在、受保护平台、已经下载过（按清单里的平台 + 媒体 ID 判断）等问题，并按所选画质估算总大小、对比目标磁盘剩余空间（留 10% 余量）；可以只加入可下载的链接。
- 可选全局快捷键 ⌘⇧D（默认关闭）：把剪贴板里的链接送进应用，只在按下时读取剪贴板，不需要辅助功能权限。
- 任务页顶部显示 Torrent 汇总，点击直接进入 Torrent 页。

## 0.8.0 (build 11)

- 新增 DaVinci Resolve 对接（仅 Local 版，独立模块 `MediaFetchResolve`）：通过 Blackmagic 官方脚本 API，把素材包导入当前项目媒体池「Sooogood › 素材包名」。
  - Comments 写来源 URL，Description 写标题，Keywords 写平台；SHA-256、媒体 ID、来源写入第三方元数据。
  - SRT 字幕一起导入；工具箱生成的代理用 `LinkProxyMedia` 关联，不会重复导入成独立片段；可选同时建立时间线。
  - 同一素材包重复发送时复用已有片段和媒体夹，不会重复导入。
- 任务页和 Torrent 页的已完成项新增「发送到达芬奇」；单文件种子只导入该文件，不会导入整个下载文件夹。
- 设置页新增 DaVinci Resolve 卡片：连接状态、打开达芬奇、「下载完成后自动发送」（默认关闭，只处理本次启动后完成的任务）、「同时建立时间线」。
- 每次发送都会在素材包内追加 `resolve-imports.json`（项目、媒体夹、片段、失败项）。
- 桥接方式：请求走 stdin 传给内嵌 Python 脚本，不经过 shell；连接失败时会分别提示「达芬奇未运行」「需要把外部脚本设为本地」「没有打开的项目」。

## 0.7.0 (build 10)

- 新增 Torrent（仅 Local 版）：独立模块 `MediaFetchTorrent`，由 Homebrew 的 `transmission-daemon` 4.1 驱动（JSON-RPC 2.0）。应用启动私有守护进程：RPC 只监听 127.0.0.1 的随机端口，每次启动生成新的随机凭据，配置目录权限 0700。
- 支持磁力链接、.torrent 文件（选择、拖入、Finder 打开），系统里的 `magnet:` 链接也能交给本应用；可在开始前选择文件、标记优先文件、顺序下载，设置做种策略（完成即停 / 分享率 / 空闲时长）。
- 完成后生成 `torrent-manifest.json`（infohash、每个文件的 SHA-256）；拒绝会跳出下载目录的文件路径；「移出列表」不删除任何已下载文件。
- 首次使用需要确认合法使用说明；不提供种子搜索或索引。
- 共享的 `JSONValue`（Core）供 Transmission RPC 和后续 MCP 复用。
- Store 预检新增：Info-Store.plist 不得注册 magnet/.torrent；Local 专属模块必须有编译边界；Store 二进制中不得出现 Torrent/MCP/工具箱相关字符串。

## 0.6.0 (build 9)

- 下载失败自动重试（最多 3 次）：429 指数退避并降低分片并发；YouTube SABR / 人机验证 / 签名失败按实测可用的 `player_client` 附加列表（`default,mweb` → `default,android` → `mweb,android`）切换；403 改用 IPv4；字幕单独被限流时去掉字幕重试；已删除、私有、404 等终止型错误不重试。
- 新增 `EngineDiagnostics`：把引擎输出归类为具体原因，并给出唯一可执行的动作（登录网站 / 更新 yt-dlp / 稍后重试 / 查看磁盘 / 安装 deno），任务页以卡片呈现。
- 下载命令统一由 `YtDLPArgumentBuilder` 生成，新增网络重试、超时、`--retry-sleep exp=1:30` 和 8 路分片并发；任务页可展开查看已脱敏的实际命令。
- 下载中可暂停/继续（进程原地挂起，不丢进度）；队列运行期间阻止 Mac 闲置睡眠。
- 写清单前检查文件头，拒收伪装成媒体的 HTML 错误页；视频 manifest 升级为 schema 2，新增 `engine`（尝试次数、player_client、命令）与每个文件的 `signature`。
- 设置页新增「本机工具」面板：yt-dlp 版本下限 / 过期提醒、FFmpeg、deno 状态，并附带可复制的 brew 命令。
- 队列状态的图标和颜色集中到一个共享扩展，两个任务列表共用。

## 0.5.1 (build 7)

- 新增真正的应用内 WebKit 登录窗口：Vimeo、哔哩哔哩和优酷分别保存独立网站会话，支持清除与重启复用。
- 解析和队列任务通过注入的会话 provider 获取当前平台 Cookie，以 0600 临时文件交给引擎，结束后清理；历史和清单仅记录会话方式。旧视频历史与旧浏览器登录偏好兼容。
- Google/YouTube 内嵌登录明确显示平台限制，保留用户主动选择的浏览器兼容登录，不伪装浏览器或获取官网表单密码。
- 新增域名隔离、过期与 HttpOnly Cookie、临时文件权限/清理、旧配置兼容及非持久化 WebKit 会话测试。

## 0.5.0 (build 6)

- 新增独立的“流媒体网站登录”设置，为 YouTube、Vimeo、哔哩哔哩和优酷分别选择已登录浏览器并打开官方登录页。
- 视频页按识别到的平台自动读取对应登录配置；混合粘贴多平台链接时，每个任务保留自己的浏览器 Cookie 来源。
- 登录偏好拆为 Core 数据模型、App 持久化 Store 和可复用 SwiftUI 卡片；新增平台只需注册配置，不改下载核心。
- 只保存平台、浏览器类型和显式启用状态，不保存账号、密码、Cookie 或网站 Token；Safari 继续使用完整磁盘访问的显式权限流程。
- Vimeo/其他站点需要登录时显示可操作的中文错误，不再直接展示下载引擎的英文原始提示。

## 0.4.0 (build 5)

- 新增电影感深色首页和独立音乐页面。
- Spotify 使用 OAuth PKCE 读取身份/曲序；音频只允许本地文件或授权 DRM-free 直链。
- 增加本地扫描、版本敏感匹配、逐字节复制、M3U8 和 schema v2 manifest。
- 将代码拆为 `MediaFetchCore`、`MediaFetchVideo`、`MediaFetchMusic` 和 SwiftUI App 组合层。
- 增加品牌标志、macOS AppIcon、隐私清单、Store entitlements、商店文案和可重复 preflight。
- 保留视频历史/manifest v1，不迁移 Spotify 历史。
- 将视频工具链与音乐 metadata 探针分别封装为可替换的 toolchain；Store 使用 AVFoundation 原生扫描器，不嵌入 `yt-dlp`、`ffmpeg` 或其他第三方 helper。
- 增加 Store bundle 版本漂移、第三方 helper 排除检查，以及固定 UI 预览状态和本地回归夹具。
- 根据 Apple 审核中的第三方音视频下载限制，Store profile 将视频入口编译为说明页；完整视频下载保留在 Local profile，商店与本地渠道各自使用独立封面文案。
- 增加 `Info-Store.plist` 音乐分类、未知 profile 拒绝，以及 Store 前置失败时不覆盖现有 Local bundle 的保护。
- 设置页增加应用内隐私政策入口，并为 Reduce Transparency 使用不透明状态胶囊回退样式。
- 增加 Store 真实截图采集清单，明确固定夹具、无个人数据和 Store/Local 素材隔离要求。
- 在两个发行 plist 中声明豁免加密并由 Store preflight 校验，减少出口合规字段漂移。
- 增加 Store “查看演示”入口，使用音乐模块内的合成元数据夹具，降低 App Review 对第三方登录状态的依赖。
- 预览/测试 ViewModel 在关闭持久化时不写入 Spotify 历史，避免 UI 验收污染用户状态；Store 演示保存回归覆盖音频、M3U8 和 manifest 输出。
- 发布脚本改为 staging bundle 原子晋级，并将 VI 源稿、品牌规范、1440×900 商店封面和真实截图验收脚本纳入 Store 发布流程，降低升级时留下半成品或漏交素材的风险。
- 增加商店元数据字符/UTF-8 字节限制校验，并接入 Store 发布总检查，避免后续本地化或改文案时在 App Store Connect 才发现字段超限。
- 截图验收增加 alpha/transparency 通道检查，跟随 Apple 当前 Mac 截图规范，避免尺寸正确但上传被拒。
- Store 总预检增加可选硬门槛：上传前设置 `REQUIRE_STORE_SCREENSHOTS=1 REQUIRE_PUBLIC_WEB=1`，强制检查真实截图和公开网页模板占位符。
- Store profile 进一步在编译期排除 Local ffprobe/Process 扫描器，降低静态审核误判和未来 profile 泄漏风险；对应 Local-only 测试同步隔离。
- 增加可直接部署的隐私政策与支持页 HTML 模板；发布前仍必须替换法律主体/邮箱并部署到自己的 HTTPS 域名。
- Store 总预检增加无障碍源码回归门槛（主路由 accessibility label/hint、Reduce Motion/Transparency）；同时把 Accessibility Nutrition Labels 留给签名包人工验收，避免把静态检查误报为 Apple 表单已完成。
- 提交文档改用 Apple 当前提交、截图、审核和 build 上传入口，后续 Xcode/App Store Connect 更新时只需复核链接与清单，不改动模块边界。
- 封面渲染器改为直接输出无 alpha 的 RGB PNG，并由 Store 总预检锁定 1440×900 与无 alpha 约束，避免品牌物料在后续复用时被透明通道影响。
- 上架清单补充 Apple App Information 的 Content Rights 核对，并明确第三方内容授权证据必须由发布主体保留，不能以本地工程审计替代。
- 增加可版本控制的 `StoreAssets/Screenshots/README.md`，固定五张截图文件名并明确封面与应用截图的目录隔离。
- Store `.pkg` 构建改为 staging + 验签后原子替换，并拒绝非 `.pkg` 或含空格的输出文件名，避免升级发布留下半成品。
- `.pkg` 构建现在强制先通过真实 Store 截图和公网页面预检；VI 文档补充源稿到派生资产的唯一生成流程，并增加英文封面说明，降低后续改版漏同步风险。
- 增加 `validate_brand_assets.sh`，在打包前逐项锁定 Logo、AppIcon 尺寸、两套封面和双语封面说明，降低视觉资产升级时的漂移风险。
- 将 Bundle ID 收敛到 Core 单一来源，并在 plist、Spotify Keychain service、发布 bundle 和 Store 预检之间建立漂移检查，降低换团队或升级标识时的维护风险。
- 明确 Spotify 回环 Redirect URI 的维护约束：Dashboard 注册无端口地址，授权请求使用临时端口，并同步到设置页和 Store 提交清单。
- 发布脚本现在在写入 `dist` 前验证 Mac App/Installer Distribution identity 是否存在于当前钥匙串，避免把非空字符串误当成可用签名凭据。
- 增加 `Scripts/verify_release.sh`，集中运行两种 profile 测试、Shell/VI/元数据审计和 Store 预检；`REQUIRE_RELEASE_ARTIFACTS=1` 可在上传前强制校验真实截图、公网页面和签名 `.pkg`。
## 0.5.2 (build 8)

- 对外产品名称更新为 **Sooogood Video Catch**；应用显示名称、主界面、隐私说明、安装包、商店文案和品牌封面保持一致。
- 保留既有 `com.simon.mediafetch` Bundle ID、Swift 模块、历史记录和本地设置键，避免品牌改名造成数据或升级迁移断裂。
