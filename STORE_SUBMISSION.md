# Mac App Store 提交状态

## 已准备

- App Sandbox entitlement 模板：`Resources/MediaFetch-Store.entitlements`
- 未来 helper 隔离的 entitlement 模板（当前 Store 不嵌入 helper）：`Resources/MediaFetch-Helper.entitlements`
- 网络客户端/回环回调服务权限：`com.apple.security.network.client`、`com.apple.security.network.server`
- 用户选择目录读写：`com.apple.security.files.user-selected.read-write`
- 持久化用户选择目录：`com.apple.security.files.bookmarks.app-scope`，并由 `SecurityScopedBookmarkStore` 恢复 scope
- `PrivacyInfo.xcprivacy` 已放入 macOS app 的 `Contents/Resources`
- Store/Local Info.plist 已声明 `ITSAppUsesNonExemptEncryption=false`；发布主体仍需按实际 TLS/CryptoKit 使用情况完成 App Store Connect 出口合规问卷
- 设置页提供应用内《隐私政策》入口；公网隐私政策与支持网址仍需由发布主体提供并填入 App Store Connect
- App Store Connect 的 Content Rights、年龄分级、主/次分类和隐私字段必须由发布主体按实际第三方服务许可与发行地区填写；仓库中的 Store/Local 边界和来源清单不能替代授权证据
- `Assets.xcassets/AppIcon.appiconset` 包含 16、32、128、256、512 和 1024 点规格，并由 `actool` 编译为 `AppIcon.icns` / `Assets.car`
- Store/Local 封面已由 `Scripts/render_store_cover.swift` 重新生成并视觉检查；两份均为 1440×900、无 alpha 的 RGB PNG，Store 预检会阻止尺寸或透明通道漂移
- Store profile 使用独立的 `Resources/Info-Store.plist`（`public.app-category.music`），Local profile 保留视频工具分类；两者共用 bundle ID、版本号和图标
- 中英文商店文案和 1440×900 品牌封面：`StoreAssets/AppStoreListing.md`
- VI 主标志、品牌规范和 AppIcon 源稿：`Resources/Brand/SooogoodMediaCatchLogo.svg`、`Resources/Brand/BrandGuidelines.md`；Store preflight 会检查源稿与 1440×900 封面尺寸，避免改版时漏进商店材料
- 品牌资产独立审计：`Scripts/validate_brand_assets.sh` 会逐一检查 Logo 源稿、10 个 AppIcon 尺寸、Store/Local 封面、生成脚本和中英文封面说明，并已接入 Store 总预检
- Store 真实截图采集清单：`StoreAssets/ScreenshotCaptureChecklist.md`
- Store 截图目录与固定文件名说明：`StoreAssets/Screenshots/README.md`；目录目前只保留说明文件，五张真实截图必须从最终签名 Store bundle 采集
- 截图 PNG、尺寸和 SHA-256 验收脚本：`Scripts/validate_store_screenshots.sh`（截图目录在解锁 macOS 后生成）
- App Store Connect 元数据、审核备注和上传前字段清单：`StoreAssets/AppStoreConnectChecklist.md`
- 可托管的隐私政策网页稿：`StoreAssets/PrivacyPolicyWebTemplate.md`
- 可直接部署的隐私政策/支持页 HTML 模板：`StoreAssets/Web/privacy-policy.html`、`StoreAssets/Web/support.html`；部署说明见 `StoreAssets/Web/README.md`
- 可重复执行的发布检查：`Scripts/validate_store_submission.sh`
- 升级总门槛：`Scripts/verify_release.sh`（两种 profile 测试、Shell/VI/元数据审计和 Store 预检；设置 `REQUIRE_RELEASE_ARTIFACTS=1` 才会强制真实截图、公网页面和已验签 `.pkg`）
- 商店文案限制检查：`Scripts/validate_store_metadata.sh`（中英文名称/副标题/推广文案/描述与关键词 UTF-8 字节数）
- `Scripts/package_app.sh` 使用 staging bundle 完成构建、签名和验证后再替换 `dist/Sooogood Media Catch.app`；Store 证书/profile 失败不会留下半成品
- `Scripts/build_store_pkg.sh` 先验证 Mac Installer Distribution identity，再运行强制截图/公网页面预检，之后使用独立 staging 目录生成并通过 `pkgutil --check-signature` 后才替换目标 `.pkg`；目标文件名必须以 `.pkg` 结尾且不含空格
- Store 原生 AVFoundation 扫描说明（未来如引入 helper 的隔离门槛）：`StoreHelpers/README.md`
- Store 审核演示入口：音乐页未连接时可点击“查看演示”，只载入合成元数据，不需要 Spotify 凭据或网络。
- Spotify 回环配置：Developer Dashboard 注册 `http://127.0.0.1/oauth/spotify/callback`（无端口）；应用仅在授权请求中使用临时动态端口，依据 Spotify 当前 Redirect URI 规则。

## 提交前必须完成

1. 使用 Apple Developer 账号创建 Mac App ID、Distribution certificate 和 provisioning profile。
2. 在 App Store Connect 创建 App record，确认 SKU、主要语言、价格/可用地区，并完成付费协议、税务和银行信息（如适用）。
3. Store profile 当前不提供第三方站点视频下载，使用 AVFoundation 原生读取本地音频元数据；不能在 Store profile 运行 `/opt/homebrew`、`/usr/local/bin` 等外部程序。若要恢复视频下载，必须先取得来源方明确授权并单独通过审核评估。
4. 浏览器 Cookie 登录模式已从 Store 条件编译中移除；Local profile 仍需用户明确开启，跨应用读取 Safari/Chrome/Firefox Cookie 不能作为沙盒默认能力。
5. 在解锁的 macOS 上从同一个 Store release 包重新采集首页、音乐已载入、匹配审核、素材包完成和设置/隐私截图；截图不能带个人账号、Cookie 或 Spotify 音频字节。Local profile 的视频截图只用于独立渠道，不混入商店素材。
6. 用 Mac App Distribution identity 重跑：

   ```bash
   CODESIGN_IDENTITY="Apple Distribution: Your Team" \
   PROVISIONING_PROFILE="/path/to/MediaFetch.provisionprofile" \
   BUILD_PROFILE=store ./Scripts/package_app.sh
   REQUIRE_STORE_SCREENSHOTS=1 REQUIRE_PUBLIC_WEB=1 \
   ./Scripts/validate_store_submission.sh "dist/Sooogood Media Catch.app"
   ```

7. 生成经过签名的安装包，上传到 App Store Connect，填写隐私问卷、支持网址、隐私政策网址、出口加密问卷和审核备注。

   ```bash
   CODESIGN_IDENTITY="Apple Distribution: Your Team" \
   INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Team" \
   PROVISIONING_PROFILE="/path/to/MediaFetch.provisionprofile" \
   ./Scripts/build_store_pkg.sh
   ```

   该脚本先生成 Store profile 的 `.app`，强制通过真实截图与公网页面预检，再用 Installer Distribution identity 生成 `.pkg` 并执行 `pkgutil --check-signature`。

8. 按 `StoreAssets/AppStoreConnectChecklist.md` 填写审核账号、Spotify Development Mode allowlist、隐私政策 URL、支持 URL、年龄分级和出口合规信息。不要把 token、Client Secret 或真实私人路径写入审核备注。

## 当前机器实测（2026-08-31）

- `swift test`：59 项通过，0 failures（Local profile）。
- `swift test -Xswiftc -DMEDIAFETCH_STORE_PROFILE`：60 项通过，0 failures（Store profile，包含审核演示模式加载与保存测试；Local ffprobe 扫描测试只在 Local profile 编译）。
- Local app 已重新打包，`codesign --verify --deep --strict` 通过；当前为 ad-hoc 签名，主程序 SHA-256 为 `f3760bd539601418c0dc625a829ad8c61a9ad95f629734e5789f27831b01b160`。
- Store release 二进制构建成功（`.build/store-static-audit-latest`）；外部工具、Cookie、`ffprobe`/`ffmpegURL` 实现字符串审计为 0 matches，未包含 `Contents/Helpers`；主程序 SHA-256 为 `dd0a35f5d6a4a77a2bc369ab5bfb9dbba6e56696c5eb69f8ab8eaedd1154e005`。
- 独立 `xcrun actool --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon` smoke test 成功生成 `AppIcon.icns`、`Assets.car` 和 partial Info；打包脚本会在 staging bundle 内重复执行这一步。
- 当前发布机工具链：Xcode 26.6（Build 17F113）、macOS SDK 26.5；`productbuild`、`codesign`、`altool` 与 `notarytool` 均可定位。以后每次 release 记录 Xcode/SDK 版本，Apple 更新最低上传工具链时重新核对。
- `security find-identity -v -p codesigning` 返回 `0 valid identities found`；本机没有 provisioning profile，因此尚未生成可上传的签名 Store `.app` 或 `.pkg`。
- 真实应用截图尚未采集：当前桌面处于锁定状态，必须在解锁 macOS 上从最终签名 Store bundle 重新采集；1440×900 品牌封面不算应用截图。
- 最近一次 Store 源码预检新增并通过 Content Rights / Accessibility Nutrition Labels 清单存在性、主路由无障碍标签、Reduce Motion/Transparency 和 Store 封面无 alpha 检查；这些静态检查仍不替代 Apple 表单和签名包人工验收。

## 审核与产品承诺

- Store 文案必须准确描述为“用 Spotify 元数据整理用户拥有的本地音频并生成可追溯素材包”，不能暗示商店版保存第三方站点媒体，也不能承诺绕过 DRM、会员限制、登录控制或“下载所有流媒体”。
- 对 YouTube、Vimeo、哔哩哔哩、优酷等第三方服务，提交前应分别核对服务条款和品牌使用许可，并在审核备注中说明：Spotify 仅作元数据/曲序参考，音乐字节来自用户本地或明确授权的 DRM-free 来源。
- Apple 的 App Review Guidelines 5.2.2 要求使用、访问或展示第三方服务时具备服务方许可；5.2.3 进一步限制保存、转换或下载第三方媒体。Store profile 因此只提供 Spotify 元数据 + 用户本地/授权 DRM-free 音频桥接；本仓库的限制性 UI、来源清单和 manifest provenance 是工程控制，不能替代服务条款或 Apple 审核判断。

## 版本维护门槛

- 每次功能升级必须同时更新 `MediaFetchCore/ReleaseInfo.swift`、`Resources/Info.plist`、`Resources/Info-Store.plist`、测试夹具和变更日志。
- Bundle ID 由 `MediaFetchCore/ReleaseInfo.swift` 统一提供；App plist、Spotify Keychain service 和最终 bundle 会在预检中阻止部分修改。更换 Developer 团队前先同步 App Store record、Keychain service 和迁移说明。
- API 或平台变化只改对应模块；Core 的 manifest schema 只增不改，旧历史保持可读。
- 任何 Store profile 的 capability 变化都必须重新做沙盒回归、`codesign --verify --deep --strict` 和临时目录/网络权限测试。
- 不把“本地 preflight 通过”表述成“已获 Apple 审核”；两者是不同验收门槛。
- 音频扫描仍需在真实沙盒签名包中验证 AVFoundation 对 security-scoped 文件的访问；Store profile 不使用视频下载 staging，也不需要第三方 metadata helper。

Apple 的打包检查还要求 Bundle ID、版本/build、版权和分类与 App Store Connect 记录一致，所有嵌套 executable 均签名；`productbuild` 只生成一个无空格文件名的 `.pkg` 组件。每次升级必须递增 build，不复用已经提交过的 build 号。发布人还需按当前 Apple 页面复核上传入口、App 信息字段、Mac 截图规格、审核规则和 Accessibility Nutrition Labels：[Submitting apps](https://developer.apple.com/app-store/submitting/)、[App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)、[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)、[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 和 [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)。
