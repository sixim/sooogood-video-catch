# MediaFetch 隐私政策网页稿

> 发布前请由产品负责人或法律主体审核，并把尖括号字段替换为真实信息。此文件是可托管的网页稿，不是法律意见；App Store Connect 中的隐私政策 URL 必须指向公开可访问的正式页面。

## MediaFetch 隐私政策

生效日期：`<EFFECTIVE_DATE>`  
运营主体：`<LEGAL_ENTITY>`  
联系邮箱：`<SUPPORT_EMAIL>`

### 我们处理的信息

MediaFetch 是本地优先的 macOS 工具。除非用户主动连接 Spotify 或加载网络媒体页面，应用不会向 MediaFetch 自有服务器上传文件、Cookie、播放输出或素材内容。应用不包含广告、跨 App 跟踪或遥测服务。

### Spotify 连接

Spotify OAuth 使用 PKCE。Client ID 保存在本机设置；access token 和 refresh token 只保存在 macOS 钥匙串。应用读取曲目身份、专辑、歌单顺序以及必要的封面和外部链接元数据。Spotify 元数据缓存最多保留 24 小时；用户在设置中断开账号后，令牌和缓存会被删除。

MediaFetch 不请求 Spotify 音频、不读取 Spotify Cookie、不抓取 Spotify 客户端缓存，也不录制播放输出。音频素材只来自用户明确选择的本地文件或用户明确授权的 DRM-free HTTPS 直链。

### 本地文件与素材包

用户选择的资料夹只以 security-scoped bookmark 形式保存访问授权。扫描过程只读，用于读取音频标签、时长、编码、ISRC 和文件大小。保存时只复制用户确认的文件，并在复制前后计算 SHA-256；原件不移动、不改名、不修改标签。输出目录、文件名、哈希和匹配依据写入用户选择的素材包 manifest。

### 视频与浏览器登录状态

Local profile 只有在用户明确启用时才会把浏览器登录状态交给本机下载引擎使用，MediaFetch 不保存 Cookie 文件。Mac App Store profile 不读取浏览器 Cookie，也不提供第三方站点音视频下载。

### 删除与联系

用户可以在设置中断开 Spotify 并删除本地凭据，也可以删除应用支持目录中的历史和缓存文件。应用不会自动删除、移动或重命名原始媒体。隐私问题或删除请求请联系 `<SUPPORT_EMAIL>`。

### 政策更新

政策更新后会在本页修改生效日期。重大变化会在应用更新说明中提示。
