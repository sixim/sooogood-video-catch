# MediaFetch

MediaFetch 是一个面向 macOS 的本地媒体下载器。它用 `yt-dlp` 解析平台实际提供的媒体流，用 `FFmpeg` 做必要的无损封装；默认不重新编码画面或声音。

## 当前能力

- 解析单条 YouTube、Vimeo 或其他 `yt-dlp` 支持网站的链接
- 显示标题、作者、时长与检测到的最高分辨率
- 最高画质：最佳视频流 + 最佳音频流，无损合并为 MKV
- 原始流：分别保存平台直接提供的视频与音频文件
- 兼容 MP4：优先使用 H.264 + M4A，无损封装为剪辑软件更易接受的 MP4
- 下载进度、速度、预计剩余时间、取消和完成文件定位
- 参数以数组形式传给下载引擎，不经过 shell
- Vimeo 登录可见内容可由用户明确启用 Safari、Chrome 或 Firefox 登录状态

## 环境

遵循本机统一标准，CLI 依赖通过 Homebrew 安装：

```bash
brew install yt-dlp ffmpeg
```

开发运行：

```bash
swift run MediaFetch
```

打包成标准 macOS 应用（输出到 `dist/MediaFetch.app`）：

```bash
./Scripts/package_app.sh
open dist/MediaFetch.app
```

测试：

```bash
swift test
```

## “原始文件”的准确含义

流媒体网站通常不会公开上传者最初上传的母版文件。MediaFetch 能保存的是平台当前向该账户/地区/设备提供的最高质量编码流：

- “保留平台原始音视频流”不会转码，但视频和音频通常是两个文件。
- “最高画质”同样不转码，只用 FFmpeg 把最佳视频和音频重新封装到一个 MKV 容器。
- 分辨率相同不代表编码码率、色深、HDR 或音轨一定相同，最终以解析出的格式为准。

## Vimeo

Vimeo 的网页客户端目前可能要求登录，即使链接本身可以在已登录浏览器中观看。遇到这种情况，在应用中勾选“使用浏览器登录状态”，并选择已经登录 Vimeo 的 Safari、Google Chrome 或 Firefox。应用不会默认读取 Cookie，也不会保存 Cookie 文件；登录状态只作为参数交给本机 `yt-dlp` 进程。

## 使用边界

仅用于你拥有权利、已获许可或平台明确允许下载的内容。本项目不实现 DRM 绕过，也不承诺每个网站永久可用；网站更新后通常需要同步更新 `yt-dlp`。
