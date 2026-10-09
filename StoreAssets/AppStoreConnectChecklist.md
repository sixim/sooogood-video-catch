# App Store Connect 提交清单

这份清单是 Sooogood Media Catch 每个 Store release 的提交入口。它区分“仓库已准备”和“必须由发布主体填写或提供”的事项，不把本地 preflight 误当作 Apple 审核通过。

## 已由仓库准备

- [x] App 名称、中文/英文副标题、推广文案、关键词和描述草案：见 `AppStoreListing.md`。
- [x] Store profile 的 `Info-Store.plist`，分类为 `public.app-category.music`。
- [x] Store bundle 使用显式 Bundle ID `com.simon.mediafetch`，版本号集中由 `MediaFetchCore/ReleaseInfo.swift` 校验。
- [x] App Sandbox、用户选择目录、security-scoped bookmark 和隐私清单模板。
- [x] AppIcon 16、32、128、256、512、1024 规格与 `AppIcon.icns` 构建路径。
- [x] Store/Local 功能边界说明：Store 不提供第三方站点音视频下载，不读取浏览器 Cookie，使用 AVFoundation 原生读取本地音频 metadata。
- [x] 两份 Info.plist 已声明 `ITSAppUsesNonExemptEncryption=false`；发布主体仍需在 App Store Connect 确认出口合规问卷与实际发行地区一致。
- [x] 五张真实截图的采集场景和隐私检查：见 `ScreenshotCaptureChecklist.md`。
- [x] 中英文名称/副标题/推广文案/描述/关键词已按 Apple 当前字符与 UTF-8 字节限制校验：`Scripts/validate_store_metadata.sh`。
- [x] 审核备注草稿：见下方“审核备注模板”。

## 发布主体必须填写

- [ ] Apple Developer Program 会员有效，且 App Store Connect 的 Paid Applications Agreement、税务和银行信息已完成（如适用）。
- [ ] 使用 Apple 当前支持的 Xcode/SDK 构建并记录版本；本机审计记录为 Xcode 26.6 / macOS SDK 26.5，提交前重新核对 Apple 的最新上传要求。
- [ ] 在 App Store Connect 创建 App record，确认 SKU、主要语言、价格与可用地区。
- [ ] App Store Connect 的 Bundle ID 与 Apple Developer App ID 一致。
- [ ] `CODESIGN_IDENTITY`：Mac App Distribution 证书（钥匙串名称通常为 `Apple Distribution: ...` 或 `3rd Party Mac Developer Application: ...`）。
- [ ] `PROVISIONING_PROFILE`：对应团队、Bundle ID 和 Store entitlements 的 profile。
- [ ] `INSTALLER_IDENTITY`：Mac Installer Distribution 证书（钥匙串名称通常为 `3rd Party Mac Developer Installer: ...`）。
- [ ] `CFBundleVersion` 相对上一个已提交 build 严格递增；不要复用 build 5。
- [ ] 公网隐私政策 URL：必须与应用内政策、法律主体、地区和联系方式一致。
- [ ] 支持 URL、支持邮箱和版权信息。
- [ ] 将 `StoreAssets/Web/` 页面部署到自己的 HTTPS 域名，替换法律主体、邮箱和生效日期占位符；模板不等于已发布的公开 URL。
- [ ] 在 Spotify Developer Dashboard 注册 `http://127.0.0.1/oauth/spotify/callback`（不带端口）；应用连接时按 Spotify 回环规则临时分配端口，并将该端口带入授权请求。
- [ ] Content Rights：准备 Spotify 元数据、封面/来源标识及其他第三方内容的使用许可或服务条款依据；审核要求时能够提供授权证据。
- [ ] 年龄分级问卷。
- [ ] App Privacy 问卷：说明 Spotify 元数据、Keychain 凭据和本地文件访问边界。
- [ ] Accessibility Nutrition Labels：按最终签名 Store build 实际支持情况填写 VoiceOver、Voice Control、键盘操作、较大文字、字幕/替代文本和 Reduce Motion/Transparency；不能把源码标签审计当作 Apple 表单已完成。
- [ ] 出口合规问卷：按实际使用的 TLS、CryptoKit 和发行地区填写；不要照抄模板。
- [ ] 审核联系人和审核备注中的测试步骤。
- [ ] 在真实签名 Store bundle 上验证 AVFoundation 对用户选择目录的 metadata 读取；如果未来增加 helper，再增加相应许可证、NOTICE、架构和签名审计。
- [ ] 在解锁 macOS 上从最终签名 Store bundle 采集真实截图，并记录截图目录 SHA-256。
- [ ] 运行 `Scripts/validate_store_screenshots.sh StoreAssets/Screenshots`，确认五张截图均为允许的 Mac storefront 尺寸。
- [ ] 上传前运行 `REQUIRE_STORE_SCREENSHOTS=1 REQUIRE_PUBLIC_WEB=1 ./Scripts/validate_store_submission.sh "dist/Sooogood Media Catch.app"`，将真实截图和公开网页占位符检查设为硬门槛。
- [ ] 修改商店文案后重新运行 `Scripts/validate_store_metadata.sh`，并由发布人确认商标、关键词和地区化表达。

Apple 当前提交入口、App 信息字段、Mac 截图尺寸和审核规则会随 Xcode/App Store Connect 更新；每次 release 由发布人复核官方页面：[Submitting apps](https://developer.apple.com/app-store/submitting/)、[App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)、[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)、[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 和 [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)。

## 包结构硬检查

- [ ] `Contents/Info.plist` 的 Bundle ID、版本、build、版权和分类与 App Store Connect 记录一致。
- [ ] 主程序和未来可能加入的所有嵌套 executable 都已签名并通过 `codesign --verify --deep --strict`；当前 Store 默认不包含嵌套 helper。
- [ ] `.pkg` 只包含一个 `/Applications` 组件，文件名不含空格且扩展名为 `.pkg`。
- [ ] 应用只写入 App Support/Caches 或用户通过选择器明确授权的目录；不在用户主目录任意创建隐藏数据。

## 审核备注模板

提交时把以下内容复制到 App Review Notes，并替换尖括号字段：

```text
Sooogood Media Catch Mac App Store edition is a local-first music bridge.

1. Open Settings and enter the Spotify Client ID for our review app:
   <REVIEW_CLIENT_ID>
2. Click Connect Spotify and authorize the review account:
   <REVIEW_ACCOUNT_OR_INSTRUCTIONS>
3. Open Music and paste this review playlist/album/track URL:
   <REVIEW_SPOTIFY_URL>
4. Choose the supplied review folder containing owned or licensed DRM-free audio:
   <REVIEW_FOLDER_INSTRUCTIONS>
5. Review the match states, then save the package to a user-selected folder.

Spotify is used for identity and ordering only. The app does not download Spotify
audio, read browser cookies, capture playback, or bypass DRM. The Store build does
not provide third-party site video/audio downloads.

Privacy policy: <PUBLIC_PRIVACY_POLICY_URL>
Support: <PUBLIC_SUPPORT_URL>
```

The Store build also includes **查看演示 / View Demo** on the disconnected Music
screen. It loads synthetic metadata without Spotify login, tokens, cover bytes,
or audio bytes so App Review can verify navigation and the matching UI before
using the optional review account.

不要把 access token、refresh token、Client Secret 或真实私人文件路径写入审核备注。若 Spotify Developer App 仍处于 Development Mode，提交前必须确认 Apple 审核账号已被 allowlist；否则审核人员无法完成主流程。

## 上传前最后命令

```bash
BUILD_PROFILE=store ./Scripts/package_app.sh
./Scripts/validate_store_submission.sh "dist/Sooogood Media Catch.app"
codesign --verify --deep --strict "dist/Sooogood Media Catch.app"
./Scripts/build_store_pkg.sh
pkgutil --check-signature dist/SooogoodMediaCatch.pkg
```

以上命令只在签名身份、provisioning profile 和公网材料均真实可用时执行。`BUILD_PROFILE=store` 的打包脚本会在前置条件不满足时提前退出，不覆盖已有 Local 包。
