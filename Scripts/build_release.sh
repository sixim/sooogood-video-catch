#!/bin/zsh
# Builds the release assets used by install.sh:
#   dist/release/Sooogood-Video-Catch-macOS.zip          universal (Apple silicon + Intel) Local build
#   dist/release/Sooogood-Video-Catch-macOS.zip.sha256   checksum file read by install.sh
# Publish with:  gh release create vX.Y.Z dist/release/* --title "vX.Y.Z" --notes "…"
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./Scripts/package_app.sh
app="dist/Sooogood Video Catch.app"
for binary in MediaFetch sooogood-mcp; do
    archs="$(lipo -archs "$app/Contents/MacOS/$binary")"
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { print -u2 "$binary is not universal: $archs"; exit 1; }
done
codesign --verify --deep --strict "$app"

out="dist/release"
rm -rf "$out"; mkdir -p "$out"
asset="Sooogood-Video-Catch-macOS.zip"
ditto -c -k --keepParent "$app" "$out/$asset"
(cd "$out" && shasum -a 256 "$asset" > "$asset.sha256")
version="$(defaults read "$PWD/$app/Contents/Info" CFBundleShortVersionString)"
print "Release assets for v$version:"
ls -la "$out"
cat "$out/$asset.sha256"
