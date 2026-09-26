#!/bin/sh
# Synthetic yt-dlp for BatchPreflight tests: answers --dump-single-json by URL keyword.
for last; do :; done
case "$last" in
    *gone*) printf '%s\n' 'ERROR: [youtube] x: Video unavailable' >&2; exit 1 ;;
    *login*) printf '%s\n' 'ERROR: [vimeo] 1: This video only works when logged-in' >&2; exit 1 ;;
    *dup*) printf '%s' '{"id":"dup1","extractor":"youtube","title":"Dup","filesize":10}' ;;
    *) printf '%s' '{"id":"ok1","extractor":"youtube","title":"OK","requested_formats":[{"filesize":1000},{"filesize_approx":500}]}' ;;
esac
