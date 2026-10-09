#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/Sooogood Media Catch.app"
pkg_path="${STORE_PKG_PATH:-$project_dir/dist/SooogoodMediaCatch.pkg}"
installer_identity="${INSTALLER_IDENTITY:-}"

pkg_filename="${pkg_path:t}"
[[ "$pkg_filename" == *.pkg ]] || {
    print -u2 "STORE_PKG_PATH 的文件名必须使用 .pkg 扩展名"
    exit 2
}
[[ "$pkg_filename" != *" "* ]] || {
    print -u2 "Store 安装包文件名不能包含空格：$pkg_filename"
    exit 2
}

if [[ -z "$installer_identity" ]]; then
    print -u2 "INSTALLER_IDENTITY must be a Mac Installer Distribution identity"
    exit 2
fi

available_installer_identities="$(security find-identity -v 2>/dev/null || true)"
if ! print -r -- "$available_installer_identities" | rg -F -- "$installer_identity" >/dev/null; then
    print -u2 "INSTALLER_IDENTITY 不在当前钥匙串的有效 identities 中：$installer_identity"
    print -u2 "请使用 Mac Installer Distribution / 3rd Party Mac Developer Installer identity 的完整名称。"
    exit 2
fi

BUILD_PROFILE=store "$project_dir/Scripts/package_app.sh"
# A signed bundle is not enough for an App Store upload. Enforce the two
# release-only gates here so a caller cannot accidentally produce a distributable
# package while real storefront screenshots or public web placeholders are
# still missing. The validator remains separate and reusable for CI/source
# audits when no bundle exists.
REQUIRE_STORE_SCREENSHOTS=1 \
REQUIRE_PUBLIC_WEB=1 \
    "$project_dir/Scripts/validate_store_submission.sh" "$app_dir"
mkdir -p "${pkg_path:h}"
staging_root="$(mktemp -d "${pkg_path:h}/.SooogoodMediaCatch-pkg.XXXXXX")"
staging_pkg="$staging_root/SooogoodMediaCatch.pkg"
cleanup_staging() {
    rm -rf "$staging_root"
}
trap cleanup_staging EXIT

productbuild \
    --component "$app_dir" /Applications \
    --sign "$installer_identity" \
    "$staging_pkg"
pkgutil --check-signature "$staging_pkg"
mv -f "$staging_pkg" "$pkg_path"
print "$pkg_path"
