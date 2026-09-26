#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="${1:-$project_dir/dist/Sooogood Video Catch.app}"
screenshot_dir="${STORE_SCREENSHOTS_DIR:-$project_dir/StoreAssets/Screenshots}"
require_screenshots="${REQUIRE_STORE_SCREENSHOTS:-0}"
require_public_web="${REQUIRE_PUBLIC_WEB:-0}"

[[ "$require_screenshots" == "0" || "$require_screenshots" == "1" ]] || {
    print -u2 "REQUIRE_STORE_SCREENSHOTS 只能是 0 或 1"
    exit 2
}
[[ "$require_public_web" == "0" || "$require_public_web" == "1" ]] || {
    print -u2 "REQUIRE_PUBLIC_WEB 只能是 0 或 1"
    exit 2
}

required_sources=(
    "$project_dir/Resources/Info.plist"
    "$project_dir/Resources/Info-Store.plist"
    "$project_dir/Resources/PrivacyInfo.xcprivacy"
    "$project_dir/Resources/MediaFetch-Store.entitlements"
    "$project_dir/Resources/Brand/MediaFetchLogo.svg"
    "$project_dir/Resources/Brand/BrandGuidelines.md"
    "$project_dir/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
    "$project_dir/StoreAssets/AppStoreListing.md"
    "$project_dir/StoreAssets/MediaFetch-store-cover-1440x900.png"
    "$project_dir/StoreAssets/ScreenshotCaptureChecklist.md"
    "$project_dir/StoreAssets/Screenshots/README.md"
    "$project_dir/StoreAssets/AppStoreConnectChecklist.md"
    "$project_dir/StoreAssets/PrivacyPolicyWebTemplate.md"
    "$project_dir/StoreAssets/Web/privacy-policy.html"
    "$project_dir/StoreAssets/Web/support.html"
    "$project_dir/StoreAssets/Web/README.md"
    "$project_dir/Scripts/build_store_pkg.sh"
    "$project_dir/Scripts/verify_release.sh"
    "$project_dir/Scripts/validate_brand_assets.sh"
    "$project_dir/Scripts/validate_store_screenshots.sh"
    "$project_dir/Scripts/validate_store_metadata.sh"
)

for source_path in "${required_sources[@]}"; do
    [[ -e "$source_path" ]] || { print -u2 "缺少发布材料：$source_path"; exit 2; }
done

"$project_dir/Scripts/validate_brand_assets.sh"

rg -n '<svg[^>]+width="1024"[^>]+height="1024"[^>]+viewBox="0 0 1024 1024"' "$project_dir/Resources/Brand/MediaFetchLogo.svg" >/dev/null || {
    print -u2 "MediaFetchLogo.svg 必须保留 1024×1024 viewBox 源稿"
    exit 2
}
rg -n '## 封面说明|1440×900|MediaFetch-store-cover-1440x900\.png' "$project_dir/StoreAssets/AppStoreListing.md" >/dev/null || {
    print -u2 "商店文案缺少封面说明或 1440×900 封面引用"
    exit 2
}
rg -n 'Content Rights|Accessibility Nutrition Labels' "$project_dir/StoreAssets/AppStoreConnectChecklist.md" >/dev/null || {
    print -u2 "App Store Connect 清单缺少 Content Rights 或 Accessibility Nutrition Labels 项"
    exit 2
}
"$project_dir/Scripts/validate_store_metadata.sh" "$project_dir/StoreAssets/AppStoreListing.md"

if [[ "$require_public_web" == "1" ]]; then
    # HTML 页面会把尖括号实体编码；mailto 属性还会把它们百分号编码，两个形态都必须拦截。
    if rg -n -F \
        -e '&lt;LEGAL_ENTITY&gt;' \
        -e '&lt;SUPPORT_EMAIL&gt;' \
        -e '&lt;EFFECTIVE_DATE&gt;' \
        -e '&lt;SUPPORT_URL&gt;' \
        -e '%3CSUPPORT_EMAIL%3E' \
        "$project_dir/StoreAssets/Web/privacy-policy.html" \
        "$project_dir/StoreAssets/Web/support.html" >/dev/null; then
        print -u2 "公开隐私政策/支持页仍包含模板占位符；替换真实法律主体、邮箱、日期和 URL 后再提交"
        exit 2
    fi
    print "Store public web templates contain no placeholders. Confirm the deployed HTTPS URLs separately."
else
    print "Store public web check deferred; set REQUIRE_PUBLIC_WEB=1 before upload."
fi

if [[ "$require_screenshots" == "1" ]]; then
    "$project_dir/Scripts/validate_store_screenshots.sh" "$screenshot_dir"
else
    print "Store screenshot check deferred; set REQUIRE_STORE_SCREENSHOTS=1 before upload."
fi
cover_width="$(sips -g pixelWidth "$project_dir/StoreAssets/MediaFetch-store-cover-1440x900.png" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
cover_height="$(sips -g pixelHeight "$project_dir/StoreAssets/MediaFetch-store-cover-1440x900.png" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
[[ "$cover_width" == "1440" && "$cover_height" == "900" ]] || {
    print -u2 "商店封面必须是 1440×900 PNG，当前为 ${cover_width:-unknown}×${cover_height:-unknown}"
    exit 2
}
cover_alpha="$(sips -g hasAlpha "$project_dir/StoreAssets/MediaFetch-store-cover-1440x900.png" 2>/dev/null | awk '/hasAlpha:/ {print $2}')"
[[ "$cover_alpha" == "no" ]] || {
    print -u2 "商店封面必须是无 alpha 的实心 PNG，当前为 ${cover_alpha:-unknown}"
    exit 2
}

rg -n 'func loadDemoCollection' "$project_dir/Sources/MediaFetch/SpotifyBridgeViewModel.swift" >/dev/null || {
    print -u2 "Store 审核演示入口缺失：SpotifyBridgeViewModel.loadDemoCollection"
    exit 2
}
rg -n '查看演示' "$project_dir/Sources/MediaFetch/MusicBridgeView.swift" >/dev/null || {
    print -u2 "Store 审核演示入口缺失：音乐页“查看演示”按钮"
    exit 2
}

# Keep the accessibility contract visible at the source boundary. This is a
# lightweight regression guard, not a substitute for VoiceOver/Voice Control
# review on the signed app. A future view split must update this list together
# with the UI tests and screenshot checklist rather than silently dropping
# Reduce Motion/Transparency support or labels on the primary routes.
accessibility_sources=(
    "$project_dir/Sources/MediaFetch/HomeView.swift"
    "$project_dir/Sources/MediaFetch/MusicBridgeView.swift"
    "$project_dir/Sources/MediaFetch/SettingsView.swift"
    "$project_dir/Sources/MediaFetch/ContentView.swift"
)
for accessibility_source in "${accessibility_sources[@]}"; do
    [[ -f "$accessibility_source" ]] || { print -u2 "无障碍审计源文件缺失：$accessibility_source"; exit 2; }
done
rg -n '\.accessibility(Label|Hint)\(' "${accessibility_sources[@]}" >/dev/null || {
    print -u2 "主路由缺少可访问性标签/提示"
    exit 2
}
rg -n 'accessibilityReduceMotion' "$project_dir/Sources/MediaFetch" >/dev/null || {
    print -u2 "缺少 Reduce Motion 分支；请在动画组件中保留系统减弱动态效果设置"
    exit 2
}
rg -n 'accessibilityReduceTransparency' "$project_dir/Sources/MediaFetch" >/dev/null || {
    print -u2 "缺少 Reduce Transparency 分支；请在材质组件中保留不透明回退"
    exit 2
}
print "Store accessibility source audit passed; perform VoiceOver/Voice Control and Accessibility Nutrition Label review on the signed build."

plutil -lint "$project_dir/Resources/Info.plist" >/dev/null
plutil -lint "$project_dir/Resources/Info-Store.plist" >/dev/null
plutil -lint "$project_dir/Resources/PrivacyInfo.xcprivacy" >/dev/null
plutil -lint "$project_dir/Resources/MediaFetch-Store.entitlements" >/dev/null

core_version="$(rg -m1 'public static let version = ' "$project_dir/Sources/MediaFetchCore/ReleaseInfo.swift" | sed -E 's/.*= "([^"]+)".*/\1/')"
core_bundle_id="$(rg -m1 'public static let bundleIdentifier = ' "$project_dir/Sources/MediaFetchCore/ReleaseInfo.swift" | sed -E 's/.*= "([^"]+)".*/\1/')"
plist_version="$(plutil -extract CFBundleShortVersionString raw -o - "$project_dir/Resources/Info.plist")"
store_plist_version="$(plutil -extract CFBundleShortVersionString raw -o - "$project_dir/Resources/Info-Store.plist")"
plist_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$project_dir/Resources/Info.plist")"
store_plist_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$project_dir/Resources/Info-Store.plist")"
core_build="$(rg -m1 'public static let build = ' "$project_dir/Sources/MediaFetchCore/ReleaseInfo.swift" | sed -E 's/.*= "([^"]+)".*/\1/')"
plist_build="$(plutil -extract CFBundleVersion raw -o - "$project_dir/Resources/Info.plist")"
store_plist_build="$(plutil -extract CFBundleVersion raw -o - "$project_dir/Resources/Info-Store.plist")"
store_non_exempt_encryption="$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$project_dir/Resources/Info-Store.plist")"
[[ "$core_version" == "$plist_version" ]] || { print -u2 "版本号漂移：Core=$core_version Info.plist=$plist_version"; exit 2; }
[[ "$core_version" == "$store_plist_version" ]] || { print -u2 "版本号漂移：Core=$core_version Info-Store.plist=$store_plist_version"; exit 2; }
[[ -n "$core_bundle_id" ]] || { print -u2 "ReleaseInfo.swift 缺少 bundleIdentifier"; exit 2; }
[[ "$core_bundle_id" == "$plist_bundle_id" ]] || { print -u2 "Bundle ID 漂移：Core=$core_bundle_id Info.plist=$plist_bundle_id"; exit 2; }
[[ "$core_bundle_id" == "$store_plist_bundle_id" ]] || { print -u2 "Bundle ID 漂移：Core=$core_bundle_id Info-Store.plist=$store_plist_bundle_id"; exit 2; }
[[ "$core_build" == "$plist_build" ]] || { print -u2 "build 号漂移：Core=$core_build Info.plist=$plist_build"; exit 2; }
[[ "$core_build" == "$store_plist_build" ]] || { print -u2 "build 号漂移：Core=$core_build Info-Store.plist=$store_plist_build"; exit 2; }
[[ "$store_non_exempt_encryption" == "false" ]] || { print -u2 "Info-Store.plist 必须明确声明仅使用豁免加密：ITSAppUsesNonExemptEncryption=false"; exit 2; }

if rg -n '(/opt/homebrew|/usr/local/bin|cookies-from-browser|Cookies\.binarycookies)' "$project_dir/Sources/MediaFetchVideo" >/dev/null; then
    print "Store audit note: Local profile keeps external video tools/Cookie support behind a compile-time boundary."
    print "The Store profile must keep the restricted video screen and must not ship yt-dlp/ffmpeg helpers."
fi
if rg -n '(/opt/homebrew|/usr/local/bin|/usr/bin/ffprobe)' "$project_dir/Sources/MediaFetchMusic" >/dev/null; then
    print "Store audit note: music module keeps local ffprobe discovery for Local profile."
    print "Confirm the Store build selects AudioToolchain.native() and NativeAudioScanner()."
fi

if [[ ! -d "$app_dir" ]]; then
    print "Store preflight source checks passed; bundle not found: $app_dir"
    exit 0
fi

[[ -x "$app_dir/Contents/MacOS/MediaFetch" ]] || { print -u2 "应用主程序不存在或不可执行"; exit 2; }
[[ -f "$app_dir/Contents/Resources/AppIcon.icns" ]] || { print -u2 "应用图标未编译为 AppIcon.icns"; exit 2; }
[[ -f "$app_dir/Contents/Resources/Assets.car" ]] || { print -u2 "应用图标 Assets.car 缺失"; exit 2; }
[[ -f "$app_dir/Contents/Resources/PrivacyInfo.xcprivacy" ]] || { print -u2 "PrivacyInfo.xcprivacy 未放入 Contents/Resources"; exit 2; }

bundle_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_dir/Contents/Info.plist")"
bundle_build="$(plutil -extract CFBundleVersion raw -o - "$app_dir/Contents/Info.plist")"
bundle_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app_dir/Contents/Info.plist")"
bundle_non_exempt_encryption="$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$app_dir/Contents/Info.plist" 2>/dev/null || true)"
[[ "$bundle_version" == "$core_version" ]] || { print -u2 "bundle 版本号漂移：Core=$core_version bundle=$bundle_version"; exit 2; }
[[ "$bundle_build" == "$core_build" ]] || { print -u2 "bundle build 号漂移：Core=$core_build bundle=$bundle_build"; exit 2; }
[[ "$bundle_bundle_id" == "$core_bundle_id" ]] || { print -u2 "bundle ID 漂移：Core=$core_bundle_id bundle=$bundle_bundle_id"; exit 2; }

codesign --verify --deep --strict "$app_dir"
entitlements="$(codesign --display --entitlements :- "$app_dir" 2>&1 || true)"
if [[ "$entitlements" != *"com.apple.security.app-sandbox"* ]]; then
    print "Local bundle preflight passed for $app_dir"
    print "App Sandbox entitlement is absent; repackage with BUILD_PROFILE=store and a Mac App Distribution identity before upload."
    exit 0
fi
bundle_category="$(plutil -extract LSApplicationCategoryType raw -o - "$app_dir/Contents/Info.plist")"
[[ "$bundle_category" == "public.app-category.music" ]] || { print -u2 "Store bundle 必须使用音乐分类，当前为：$bundle_category"; exit 2; }
[[ "$bundle_non_exempt_encryption" == "false" ]] || { print -u2 "Store bundle 必须明确声明仅使用豁免加密：ITSAppUsesNonExemptEncryption=false"; exit 2; }
[[ -f "$app_dir/Contents/embedded.provisionprofile" ]] || { print -u2 "Store bundle 缺少 embedded.provisionprofile"; exit 2; }
if strings "$app_dir/Contents/MacOS/MediaFetch" | rg -n '/opt/homebrew|/usr/local/bin|/usr/bin/ffprobe|Cookies\.binarycookies|cookies-from-browser|ffprobeURL|ffprobe helper unavailable|ffmpegURL|ytDLPURL|Contents/Helpers' >/dev/null; then
    print -u2 "Store bundle 包含外部工具、Cookie 或 Local toolchain 实现标记；确认使用 NativeAudioScanner() 并排除 LocalAudioScanner/VideoToolchain"
    exit 2
fi
[[ ! -d "$app_dir/Contents/Helpers" ]] || { print -u2 "Store bundle 不得包含第三方 helper：Contents/Helpers"; exit 2; }
print "Store preflight passed for $app_dir (App Sandbox entitlement detected)"
print "注意：真实上传仍需 Mac App Distribution 证书、团队 provisioning profile、App Store Connect 元数据和原生扫描器沙盒回归。"
