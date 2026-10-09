#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
brand_dir="$project_dir/Resources/Brand"
icon_dir="$project_dir/Resources/Assets.xcassets/AppIcon.appiconset"
listing="$project_dir/StoreAssets/AppStoreListing.md"

for required_path in \
    "$brand_dir/SooogoodMediaCatchLogo.svg" \
    "$brand_dir/BrandGuidelines.md" \
    "$project_dir/Scripts/render_brand_assets.swift" \
    "$project_dir/Scripts/render_store_cover.swift" \
    "$icon_dir/Contents.json" \
    "$listing"; do
    [[ -f "$required_path" ]] || {
        print -u2 "缺少品牌资产或生成源文件：$required_path"
        exit 2
    }
done

rg -n '<svg[^>]+width="1024"[^>]+height="1024"[^>]+viewBox="0 0 1024 1024"' \
    "$brand_dir/SooogoodMediaCatchLogo.svg" >/dev/null || {
    print -u2 "SooogoodMediaCatchLogo.svg 必须保留 1024×1024 viewBox 源稿"
    exit 2
}

icon_specs=(
    "icon_16.png:16"
    "icon_32.png:32"
    "icon_32_1x.png:32"
    "icon_64.png:64"
    "icon_128.png:128"
    "icon_256.png:256"
    "icon_256_1x.png:256"
    "icon_512.png:512"
    "icon_512_1x.png:512"
    "icon_1024.png:1024"
)

for spec in "${icon_specs[@]}"; do
    file_name="${spec%%:*}"
    expected_size="${spec##*:}"
    icon_path="$icon_dir/$file_name"
    [[ -f "$icon_path" ]] || {
        print -u2 "AppIcon 缺少尺寸资源：$icon_path"
        exit 2
    }
    file_description="$(file -b "$icon_path")"
    [[ "$file_description" == PNG\ image\ data* ]] || {
        print -u2 "AppIcon 必须是 PNG：$icon_path（$file_description）"
        exit 2
    }
    width="$(sips -g pixelWidth "$icon_path" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
    height="$(sips -g pixelHeight "$icon_path" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
    [[ "$width" == "$expected_size" && "$height" == "$expected_size" ]] || {
        print -u2 "AppIcon 尺寸不匹配：$icon_path（${width:-unknown}×${height:-unknown}，应为 ${expected_size}×${expected_size}）"
        exit 2
    }
    rg -n -F "\"$file_name\"" "$icon_dir/Contents.json" >/dev/null || {
        print -u2 "AppIcon Contents.json 未引用资源：$file_name"
        exit 2
    }
done

for cover_name in \
    "Sooogood-Media-Catch-store-cover-1440x900.png" \
    "Sooogood-Media-Catch-local-cover-1440x900.png"; do
    cover_path="$project_dir/StoreAssets/$cover_name"
    [[ -f "$cover_path" ]] || {
        print -u2 "缺少品牌封面：$cover_path"
        exit 2
    }
    cover_width="$(sips -g pixelWidth "$cover_path" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
    cover_height="$(sips -g pixelHeight "$cover_path" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
    cover_alpha="$(sips -g hasAlpha "$cover_path" 2>/dev/null | awk '/hasAlpha:/ {print $2}')"
    [[ "$cover_width" == "1440" && "$cover_height" == "900" ]] || {
        print -u2 "品牌封面必须是 1440×900：$cover_path（${cover_width:-unknown}×${cover_height:-unknown}）"
        exit 2
    }
    [[ "$cover_alpha" == "no" ]] || {
        print -u2 "品牌封面必须是无 alpha 的 RGB PNG：$cover_path（hasAlpha=${cover_alpha:-unknown}）"
        exit 2
    }
done

rg -n 'SooogoodMediaCatchLogo\.svg|render_brand_assets\.swift|render_store_cover\.swift' \
    "$brand_dir/BrandGuidelines.md" >/dev/null || {
    print -u2 "BrandGuidelines.md 缺少源稿/生成流程说明"
    exit 2
}
rg -n '## 封面说明|## Cover notes|Sooogood-Media-Catch-store-cover-1440x900\.png' \
    "$listing" >/dev/null || {
    print -u2 "商店文案缺少中文/英文封面说明或封面引用"
    exit 2
}

print "Brand asset audit passed: Logo source, ${#icon_specs} AppIcon sizes, Store/Local covers, generation docs and cover notes."
