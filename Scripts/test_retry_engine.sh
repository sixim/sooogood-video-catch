#!/bin/sh
# Synthetic yt-dlp used only by EngineResilienceTests. Never touches the network.
# Call 1 fails like YouTube's SABR-only response; call 2 succeeds and writes a
# tiny ISO-BMFF file into a package folder.
set -eu
count=0
[ -f "$MF_TEST_STATE" ] && count=$(cat "$MF_TEST_STATE")
count=$((count + 1))
printf '%s' "$count" > "$MF_TEST_STATE"
printf '%s\n' "$*" >> "$MF_TEST_REPORT"
dest=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --paths) shift; dest="$1" ;;
    esac
    shift
done
if [ "$count" = 1 ]; then
    printf '%s\n' 'WARNING: [youtube] abc: YouTube is forcing SABR streaming for this client' >&2
    printf '%s\n' 'ERROR: [youtube] abc: Requested format is not available' >&2
    exit 1
fi
pkg="$dest/Synthetic [abc]"
mkdir -p "$pkg"
printf '\000\000\000\030ftypisom\000\000\000\000isomiso2' > "$pkg/Synthetic [abc].mp4"
printf '%s\n' 'MF_ID|abc' 'MF_TITLE|Synthetic' 'MF_PLATFORM|youtube' 'MF_FORMAT|18|640x360|avc1|mp4a|mp4'
printf '%s\n' "MF_FILE|$pkg/Synthetic [abc].mp4"
exit 0
