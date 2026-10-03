#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
dist_dir="$project_dir/dist"
brand_app_name="Sooogood Video Catch"
app_dir="$dist_dir/$brand_app_name.app"
legacy_app_dir="$dist_dir/MediaFetch.app"
build_profile="${BUILD_PROFILE:-local}"
signing_identity="${CODESIGN_IDENTITY:--}"
provisioning_profile="${PROVISIONING_PROFILE:-}"
scratch_path="$project_dir/.build/package-$build_profile"

case "$build_profile" in
    local|store) ;;
    *)
        print -u2 "BUILD_PROFILE must be local or store (received: $build_profile)"
        exit 2
        ;;
esac

cd "$project_dir"

# Validate Store inputs before touching the branded bundle. A failed Store
# preflight must never leave a half-replaced bundle that looks like a release.
if [[ "$build_profile" == "store" ]]; then
    if [[ "$signing_identity" == "-" ]]; then
        print -u2 "BUILD_PROFILE=store requires CODESIGN_IDENTITY=Mac App Distribution (Apple Distribution: ... or 3rd Party Mac Developer Application: ...)"
        exit 2
    fi
    if [[ -z "$provisioning_profile" || ! -f "$provisioning_profile" ]]; then
        print -u2 "BUILD_PROFILE=store requires PROVISIONING_PROFILE=/path/to/embedded.provisionprofile"
        exit 2
    fi
    available_signing_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if ! print -r -- "$available_signing_identities" | rg -F -- "$signing_identity" >/dev/null; then
        print -u2 "CODESIGN_IDENTITY 不在当前钥匙串的有效 code-signing identities 中：$signing_identity"
        print -u2 "请使用 Mac App Distribution/Apple Distribution 或 3rd Party Mac Developer Application identity 的完整名称。"
        exit 2
    fi
fi

mkdir -p "$dist_dir"
staging_root="$(mktemp -d "$dist_dir/.SooogoodVideoCatch-$build_profile.XXXXXX")"
staging_app="$staging_root/$brand_app_name.app"
contents_dir="$staging_app/Contents"
cleanup_staging() {
    rm -rf "$staging_root"
}
trap cleanup_staging EXIT

build_arguments=(-c release --scratch-path "$scratch_path")
if [[ "$build_profile" == "store" ]]; then
    build_arguments+=( -Xswiftc -DMEDIAFETCH_STORE_PROFILE )
fi
# UNIVERSAL=1 builds one binary for Apple silicon and Intel (used for releases).
product_dir="$scratch_path/release"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    build_arguments+=( --arch arm64 --arch x86_64 )
    product_dir="$scratch_path/apple/Products/Release"
fi
swift build "${build_arguments[@]}"

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
rsync -a --delete "$product_dir/MediaFetch" "$contents_dir/MacOS/MediaFetch"
if [[ "$build_profile" == "local" ]]; then
    # MCP helper for AI agents (Local only; the Store validator rejects it).
    rsync -a "$product_dir/sooogood-mcp" "$contents_dir/MacOS/sooogood-mcp"
fi
plist_source="Resources/Info.plist"
if [[ "$build_profile" == "store" ]]; then
    plist_source="Resources/Info-Store.plist"
fi
rsync -a "$plist_source" "$contents_dir/Info.plist"
rsync -a "Resources/PrivacyInfo.xcprivacy" "$contents_dir/Resources/PrivacyInfo.xcprivacy"
# Interface translations: the String Catalog compiles to one .lproj per language
# (en, fr, de, ja, ko, zh-Hans); Bundle.main serves all modules and the MCP helper.
find "$contents_dir/Resources" -maxdepth 1 -name "*.lproj" -exec rm -rf {} +
xcrun xcstringstool compile "Resources/Localizable.xcstrings" --output-directory "$contents_dir/Resources" >/dev/null

if [[ -d "Resources/Assets.xcassets" ]]; then
    partial_info_plist="$contents_dir/Resources/Assets-PartialInfo.plist"
    xcrun actool \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$partial_info_plist" \
        --compile "$contents_dir/Resources" \
        "Resources/Assets.xcassets" \
        >/dev/null
    rm -f "$partial_info_plist"
fi

if [[ "$build_profile" == "store" ]]; then
    # Store profile uses the AVFoundation NativeAudioScanner. Remove any
    # stale helper/profile from an earlier package before signing the bundle.
    rm -rf "$contents_dir/Helpers"
    cp "$provisioning_profile" "$contents_dir/embedded.provisionprofile"
    codesign --force --options runtime --timestamp \
        --entitlements "Resources/MediaFetch-Store.entitlements" \
        --sign "$signing_identity" "$staging_app"
else
    # Never let a previous Store build's helper/profile leak into a Local build.
    rm -rf "$contents_dir/Helpers" "$contents_dir/embedded.provisionprofile"
    codesign --force --deep --sign "$signing_identity" "$staging_app"
fi

codesign --verify --deep --strict "$staging_app"

# Promote only after the staged bundle has passed signing and verification. A
# failed codesign or resource copy therefore cannot replace a known-good app.
previous_app=""
if [[ -e "$app_dir" ]]; then
    previous_app="$dist_dir/.SooogoodVideoCatch-previous-$$.app"
    mv "$app_dir" "$previous_app"
elif [[ -e "$legacy_app_dir" ]]; then
    # Replace the former public bundle name on the next local package build;
    # source targets and CFBundleIdentifier remain unchanged for compatibility.
    previous_app="$dist_dir/.SooogoodVideoCatch-previous-$$.app"
    mv "$legacy_app_dir" "$previous_app"
fi
if ! mv "$staging_app" "$app_dir"; then
    if [[ -n "$previous_app" && -e "$previous_app" ]]; then
        mv "$previous_app" "$app_dir"
    fi
    exit 1
fi
if [[ -n "$previous_app" && -e "$previous_app" ]]; then
    rm -rf "$previous_app"
fi

echo "$app_dir ($build_profile profile)"
