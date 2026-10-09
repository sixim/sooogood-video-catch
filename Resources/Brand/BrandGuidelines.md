# Sooogood Media Catch 视觉识别（0.5）

## 品牌定位

Sooogood Media Catch 是一个本地优先、可审计的媒体保存工具。视觉关键词是“电影感、克制、可信、可追溯”：让用户一眼看到来源、状态和保存结果，而不是被装饰性动效分散注意力。

## 核心标志

`SooogoodMediaCatchLogo.svg` 是唯一主标志源文件。标志由胶片孔、向下保存箭头和蓝紫到青绿色的连续强调色组成。应用图标由同一 SVG 渲染，不能单独修改比例、颜色或箭头方向。

- 最小显示尺寸：数字界面 20 pt，营销图 96 px。
- 安全区：标志外沿至少保留自身高度的 12%。
- 深色背景优先；浅色背景必须使用带 `#141821` 底板的版本。
- 不在 Logo 之外额外添加投影、描边、渐变覆盖层或平台 Logo；Spotify 仅作为来源标识使用。

## 资产生成与版本维护

- 源稿只保留在 `SooogoodMediaCatchLogo.svg`；`Assets.xcassets/AppIcon.appiconset/*.png` 是由 `Scripts/render_brand_assets.swift` 生成的派生文件，不能手工逐尺寸修改。
- 改动 Logo、色彩或安全区后，从仓库根目录重新运行 `swift Scripts/render_brand_assets.swift`，再用 `xcrun actool` 生成 `AppIcon.icns` 与 `Assets.car`；Store 打包脚本会在 staging bundle 中重复执行资源编译。
- 商店和本地封面分别由 `Scripts/render_store_cover.swift`（默认 Store、传入 `--local` 为 Local）生成；封面文案、颜色和尺寸令牌只在脚本与本文件维护。
- 每次视觉改版必须同时更新源稿、派生图、`AppStoreListing.md` 的封面说明和 `CHANGELOG.md`，并在 `STORE_SUBMISSION.md` 记录尺寸、alpha 状态及签名包验收结果。
- App Store 截图属于最终签名包的独立交付物，不得从封面或设计稿复制；固定文件名和验收命令见 `StoreAssets/Screenshots/README.md`。

## 色彩令牌

| 令牌 | HEX | 用途 |
|---|---|---|
| Canvas | `#0A0C11` | 主背景 |
| Surface | `#141821` | 一级卡片 |
| Surface Elevated | `#1B202C` | 工具条、弹层 |
| Text Primary | `#F5F7FA` | 主文字 |
| Text Secondary | `#9BA4B5` | 次要说明 |
| Video Blue | `#4B8DFF` | 视频操作与状态 |
| Music Violet | `#8067FF` | 音乐入口 |
| Music Teal | `#32C7A0` | 音乐完成状态 |

颜色不能作为状态的唯一表达；必须同时显示文字和 SF Symbol。正文与背景保持至少 4.5:1 对比度。

## 字体与版式

- SF Pro Display：页面标题、数字和关键状态。
- SF Pro Text：正文、表格和辅助说明。
- 8 pt 网格；卡片圆角 16–18 pt；主要内容最大宽度 1,120 pt。
- 动效时长 180–220 ms；Reduce Motion 开启时改为淡入或无动效。

## 商店封面方向

商店版主标题：`把属于你的音频，整理在本地。`

商店版副标题：`Sooogood Media Catch · 音乐桥接与可追溯素材`

辅助文案：`本地优先 · 权限清晰 · 可追溯素材包。用 Spotify 曲目顺序整理你拥有的本地音频。`

封面构图：左侧放标志与主标题，右侧放“音乐 / 可追溯”两张功能卡片的抽象轮廓；商店封面不使用 Spotify 封面做背景，不暗示可下载 Spotify 音频，不展示“破解”“绕过 DRM”或第三方站点下载承诺。非商店本地完整版另用 `Sooogood-Media-Catch-local-cover-1440x900.png`，可保留“视频 / 音乐”双入口，但不得与商店版截图或文案混用。
