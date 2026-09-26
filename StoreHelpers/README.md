# Store profile helper contract

当前 Store profile 使用 `MediaFetchMusic.NativeAudioScanner` 和 AVFoundation 原生读取音频 metadata，`Scripts/package_app.sh` 不再要求或复制第三方 helper。视频下载器仍只存在于单独分发的 Local profile，Store 包不会嵌入 `yt-dlp` 或 `ffmpeg`。

这个目录保留为未来隔离边界的说明。如果以后因格式覆盖需要增加 helper，必须先满足以下条件，再修改 Store 打包脚本：

- arm64 或 universal2，且不依赖 `/opt/homebrew`、`/usr/local`、外部 Python 或其他 app 外路径；
- 只通过参数和标准输入/输出与 MediaFetch 通信，不读取浏览器 Cookie；
- 不向 app bundle 外写入临时文件；音频扫描只读用户明确选择的资料夹，输出素材包由主 app 写入用户选择的目录；
- 先用 Apple Distribution 证书签名，再由 app 签名流程统一验证；
- helper 自身必须是 arm64/universal2 Mach-O，并使用最小化的 sandbox entitlements；
- 随包提供完整的上游许可证、NOTICE 和源码获取方式；如果未来重新启用视频 helper，必须另行确认 FFmpeg/yt-dlp 的许可与审核条件。

当前仓库不伪造或重新分发第三方二进制；原生实现是 Store 的默认路径，helper 不是当前提交前置条件。
