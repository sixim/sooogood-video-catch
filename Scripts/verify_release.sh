#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/Sooogood Media Catch.app"
pkg_path="${STORE_PKG_PATH:-$dist_dir/SooogoodMediaCatch.pkg}"
require_release_artifacts="${REQUIRE_RELEASE_ARTIFACTS:-0}"

[[ "$require_release_artifacts" == "0" || "$require_release_artifacts" == "1" ]] || {
    print -u2 "REQUIRE_RELEASE_ARTIFACTS 只能是 0 或 1"
    exit 2
}

cd "$project_dir"

print "== Local profile tests =="
swift test

print "== Store profile tests =="
swift test -Xswiftc -DMEDIAFETCH_STORE_PROFILE

print "== Shell and whitespace checks =="
zsh -n Scripts/*.sh
git diff --check

print "== Brand assets =="
"$project_dir/Scripts/validate_brand_assets.sh"

print "== Store metadata =="
"$project_dir/Scripts/validate_store_metadata.sh"

print "== Store source and bundle preflight =="
"$project_dir/Scripts/validate_store_submission.sh" "$app_dir"

if [[ -d "$dist_dir" ]] && find "$dist_dir" -maxdepth 1 -name '.SooogoodMediaCatch-*' -print -quit | rg -q .; then
    print -u2 "dist 中存在未清理的 Sooogood Media Catch staging 目录；请先检查上一次打包失败原因。"
    exit 2
fi

if [[ "$require_release_artifacts" == "1" ]]; then
    [[ -d "$app_dir" ]] || { print -u2 "REQUIRE_RELEASE_ARTIFACTS=1 要求存在 Store .app：$app_dir"; exit 2; }
    REQUIRE_STORE_SCREENSHOTS=1 REQUIRE_PUBLIC_WEB=1 \
        "$project_dir/Scripts/validate_store_submission.sh" "$app_dir"
    [[ -f "$pkg_path" ]] || { print -u2 "REQUIRE_RELEASE_ARTIFACTS=1 要求存在签名 .pkg：$pkg_path"; exit 2; }
    pkgutil --check-signature "$pkg_path"
fi

print "Release verification passed."
if [[ "$require_release_artifacts" != "1" ]]; then
    print "提示：准备真实上传时设置 REQUIRE_RELEASE_ARTIFACTS=1，强制检查截图、公网页面和签名 .pkg。"
fi
