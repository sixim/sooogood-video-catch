#!/bin/sh
# Synthetic engine used only by InAppLoginTests. Does not access the network.
set -eu
cookie_path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --cookies) shift; cookie_path="$1" ;;
        --cookies-from-browser) exit 91 ;;
    esac
    shift
done
[ -n "$cookie_path" ] && [ -f "$cookie_path" ] || exit 92
[ "$(stat -f '%Lp' "$cookie_path")" = 600 ] || exit 93
printf '%s' "$cookie_path" > "$MF_TEST_REPORT"
if [ "${MF_TEST_WAIT:-0}" = 1 ]; then
    trap 'exit 130' INT TERM
    while :; do sleep 0.1; done
fi
printf '%s\n' 'ERROR: The web client only works when logged-in' >&2
exit 1
