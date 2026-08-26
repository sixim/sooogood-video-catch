#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/MediaFetch.app"
contents_dir="$app_dir/Contents"

cd "$project_dir"
swift build -c release

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
rsync -a --delete ".build/release/MediaFetch" "$contents_dir/MacOS/MediaFetch"
rsync -a "Resources/Info.plist" "$contents_dir/Info.plist"

codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
