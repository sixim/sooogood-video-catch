#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
screenshot_dir="${1:-$project_dir/StoreAssets/Screenshots}"

required_screenshots=(
    "store-01-home.png"
    "store-02-loaded.png"
    "store-03-review.png"
    "store-04-complete.png"
    "store-05-settings.png"
)
allowed_sizes=(
    "1280x800"
    "1440x900"
    "2560x1600"
    "2880x1800"
)

if [[ ! -d "$screenshot_dir" ]]; then
    print -u2 "缺少真实 Store 截图目录：$screenshot_dir"
    print -u2 "请在解锁 macOS 上从最终签名 Store bundle 采集五张截图后再运行此脚本。"
    exit 2
fi

for screenshot_name in "${required_screenshots[@]}"; do
    screenshot_path="$screenshot_dir/$screenshot_name"
    [[ -f "$screenshot_path" ]] || {
        print -u2 "缺少 Store 截图：$screenshot_path"
        exit 2
    }

    file_description="$(file -b "$screenshot_path")"
    [[ "$file_description" == PNG\ image\ data* ]] || {
        print -u2 "截图必须是 PNG：$screenshot_path（$file_description）"
        exit 2
    }

    has_alpha="$(sips -g hasAlpha "$screenshot_path" 2>/dev/null | awk '/hasAlpha:/ {print $2}')"
    [[ "$has_alpha" == "no" ]] || {
        print -u2 "截图不能包含 alpha/transparency 通道：$screenshot_path（hasAlpha=${has_alpha:-unknown}）"
        exit 2
    }

    width="$(sips -g pixelWidth "$screenshot_path" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
    height="$(sips -g pixelHeight "$screenshot_path" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
    size="${width}x${height}"
    if ! (( ${allowed_sizes[(I)$size]:-0} )); then
        print -u2 "截图尺寸不符合 Mac storefront 规格：$screenshot_path（$size）"
        print -u2 "允许尺寸：${(j:, :)allowed_sizes}"
        exit 2
    fi

    shasum -a 256 "$screenshot_path"
done

print "Store 截图验收通过：${#required_screenshots} 张，尺寸为 ${allowed_sizes[(I)${width}x${height}]:-已允许规格}。"
