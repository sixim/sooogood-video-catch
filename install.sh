#!/bin/bash
# Sooogood Media Catch installer — one line, no prompts, safe to hand to an agent.
#
#   curl -fsSL https://raw.githubusercontent.com/sixim/sooogood-media-catch/main/install.sh | bash
#
# Options (append after `| bash -s --`):
#   --with-mcp        also register the MCP server with Claude Code (`claude mcp add`)
#   --no-deps         skip installing yt-dlp / ffmpeg / deno with Homebrew
#   --dir DIR         install into DIR (default: /Applications, or ~/Applications if not writable)
#   --version vX.Y.Z  install a specific release instead of the latest
#   --open            launch the app when done
#
# What it does: downloads the release zip from GitHub, verifies its SHA-256 and
# code signature, quits a running copy, replaces the app, and installs the
# command-line engines with Homebrew. It never uses sudo and never runs other
# remote scripts.
set -euo pipefail

REPO="sixim/sooogood-media-catch"
ASSET="Sooogood-Media-Catch-macOS.zip"
APP_NAME="Sooogood Media Catch.app"
BUNDLE_ID="com.simon.mediafetch"

with_mcp=0; with_deps=1; open_app=0; version=""; target_dir="${SOOOGOOD_DIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-mcp) with_mcp=1 ;;
    --no-deps) with_deps=0 ;;
    --open) open_app=1 ;;
    --dir) shift; target_dir="${1:?--dir needs a path}" ;;
    --version) shift; version="${1:?--version needs a tag, e.g. v0.22.1}" ;;
    -h|--help) sed -n '2,16p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# 1. Platform
[ "$(uname -s)" = "Darwin" ] || die "Sooogood Media Catch runs on macOS only."
macos="$(sw_vers -productVersion)"
[ "${macos%%.*}" -ge 14 ] || die "macOS 14 or later is required (this Mac has $macos)."

# 2. Download and verify
if [ -n "${SOOOGOOD_BASE_URL:-}" ]; then
  base="$SOOOGOOD_BASE_URL"                      # testing / mirrors
elif [ -n "$version" ]; then
  base="https://github.com/$REPO/releases/download/$version"
else
  base="https://github.com/$REPO/releases/latest/download"
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/sooogood-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

say "Downloading $ASSET ${version:-(latest)}"
curl -fL --retry 3 --progress-bar -o "$work/$ASSET" "$base/$ASSET" || die "download failed: $base/$ASSET"
curl -fsSL --retry 3 -o "$work/$ASSET.sha256" "$base/$ASSET.sha256" || die "checksum download failed"
expected="$(awk '{print $1}' "$work/$ASSET.sha256")"
actual="$(shasum -a 256 "$work/$ASSET" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] || die "SHA-256 mismatch (expected $expected, got $actual)"
say "SHA-256 verified ($actual)"

ditto -x -k "$work/$ASSET" "$work/unpacked"
new_app="$work/unpacked/$APP_NAME"
[ -d "$new_app" ] || die "the archive does not contain $APP_NAME"
codesign --verify --deep --strict "$new_app" 2>/dev/null || die "code signature check failed"
new_version="$(defaults read "$new_app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"

# 3. Install
if [ -z "$target_dir" ]; then
  if [ -w /Applications ]; then target_dir="/Applications"; else target_dir="$HOME/Applications"; fi
fi
mkdir -p "$target_dir"
dest="$target_dir/$APP_NAME"

# Only a copy running from the folder being replaced needs to quit.
running="$dest/Contents/MacOS/SooogoodMediaCatch"
if pgrep -f "$running" >/dev/null 2>&1; then
  say "Quitting the running app"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$running" >/dev/null 2>&1 || break
    sleep 1
  done
fi

if [ -d "$dest" ]; then
  # Keep the previous copy until the new one is in place.
  mv "$dest" "$work/previous.app"
fi
if ditto "$new_app" "$dest"; then
  say "Installed Sooogood Media Catch $new_version → $dest"
else
  [ -d "$work/previous.app" ] && mv "$work/previous.app" "$dest"
  die "could not copy the app into $target_dir"
fi

# 4. Engines (Homebrew)
if [ "$with_deps" = 1 ]; then
  brew_bin="$(command -v brew || true)"
  [ -z "$brew_bin" ] && [ -x /opt/homebrew/bin/brew ] && brew_bin=/opt/homebrew/bin/brew
  [ -z "$brew_bin" ] && [ -x /usr/local/bin/brew ] && brew_bin=/usr/local/bin/brew
  if [ -n "$brew_bin" ]; then
    missing=""
    for formula in yt-dlp ffmpeg deno; do
      "$brew_bin" list --formula "$formula" >/dev/null 2>&1 || missing="$missing $formula"
    done
    if [ -n "$missing" ]; then
      say "Installing engines with Homebrew:$missing"
      # shellcheck disable=SC2086
      "$brew_bin" install $missing || warn "Homebrew could not install:$missing — run: brew install$missing"
    else
      say "Engines already installed (yt-dlp, ffmpeg, deno)"
    fi
  else
    warn "Homebrew not found. Install it from https://brew.sh, then run: brew install yt-dlp ffmpeg deno"
  fi
fi

# 5. MCP for Claude Code
mcp="$dest/Contents/MacOS/sooogood-mcp"
if [ "$with_mcp" = 1 ]; then
  if command -v claude >/dev/null 2>&1; then
    claude mcp remove sooogood >/dev/null 2>&1 || true
    claude mcp add sooogood -- "$mcp" >/dev/null && say "Registered MCP server 'sooogood' with Claude Code"
  else
    warn "Claude Code CLI not found. To register later: claude mcp add sooogood -- \"$mcp\""
  fi
fi

[ "$open_app" = 1 ] && open "$dest"

cat <<EOF

Done. Open it with:   open "$dest"
MCP server path:      $mcp
Docs:                 https://github.com/$REPO
EOF
