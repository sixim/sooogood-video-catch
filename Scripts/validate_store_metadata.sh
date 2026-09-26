#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
listing_path="${1:-$project_dir/StoreAssets/AppStoreListing.md}"

[[ -f "$listing_path" ]] || {
    print -u2 "找不到商店文案：$listing_path"
    exit 2
}

# App Store Connect 对文本字段按 Unicode 字符数计数；关键词使用 UTF-8 字节数。
extract_backticked() {
    local label="$1"
    local value
    value="$(rg -m1 "^${label}" "$listing_path" | sed -E 's/^[^`]*`([^`]*)`.*/\1/')"
    [[ "$value" != *'`'* && -n "$value" ]] || {
        print -u2 "缺少商店文案字段：$label"
        exit 2
    }
    print -r -- "$value"
}

unicode_length() {
    # /usr/bin/perl 随 macOS 提供；显式 decode 参数，避免 C locale 把中文算成多个字节。
    /usr/bin/perl -Mutf8 -e '$s=$ARGV[0]; utf8::decode($s); print scalar(split(//, $s))' "$1"
}

utf8_bytes() {
    print -rn -- "$1" | wc -c | tr -d ' '
}

check_chars() {
    local label="$1"
    local value="$2"
    local minimum="$3"
    local maximum="$4"
    local count
    count="$(unicode_length "$value")"
    (( count >= minimum && count <= maximum )) || {
        print -u2 "$label 超出字符限制：${count}（允许 ${minimum}–${maximum}）"
        exit 2
    }
    print "✓ $label：${count}/${maximum} 字符"
}

check_bytes() {
    local label="$1"
    local value="$2"
    local maximum="$3"
    local count
    count="$(utf8_bytes "$value")"
    (( count <= maximum )) || {
        print -u2 "$label 超出 UTF-8 字节限制：${count}（允许 ≤${maximum}）"
        exit 2
    }
    print "✓ $label：${count}/${maximum} bytes"
}

check_chars "中文名称" "$(extract_backticked '^- 名称：')" 2 30
check_chars "中文副标题" "$(extract_backticked '^- 副标题：')" 1 30
check_chars "中文推广文案" "$(extract_backticked '^- 推广文案：')" 0 170
check_bytes "中文关键词" "$(extract_backticked '^- 关键词：')" 100
check_chars "中文描述" "$(extract_backticked '^- 描述：')" 1 4000

check_chars "英文副标题" "$(extract_backticked '^- Subtitle:')" 1 30
check_chars "英文推广文案" "$(extract_backticked '^- Promotional text:')" 0 170
check_bytes "英文关键词" "$(extract_backticked '^- Keywords:')" 100
check_chars "英文描述" "$(extract_backticked '^- Description:')" 1 4000

print "商店元数据字段均在 App Store Connect 限制内。"
