#!/bin/bash
# Refreshes Resources/Localizable.xcstrings from the source code.
# Keys are the Chinese source strings (sourceLanguage zh-Hans). Both build
# profiles are extracted so Store-only and Local-only text is included; keys
# looked up at runtime (persisted enum raw values) come from
# Resources/LocalizationRuntimeKeys.txt. Translations already in the catalog
# are kept; strings no longer in the code are marked stale by xcstringstool.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for profile in local store; do
  flags=()
  [ "$profile" = store ] && flags=(-Xswiftc -DMEDIAFETCH_STORE_PROFILE)
  mkdir -p "$work/$profile"
  swift build --build-path "$work/build-$profile" ${flags[@]+"${flags[@]}"} \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$work/$profile" >/dev/null
done
catalog=Resources/Localizable.xcstrings
[ -f "$catalog" ] || printf '{\n  "sourceLanguage" : "zh-Hans",\n  "strings" : {},\n  "version" : "1.0"\n}\n' > "$catalog"
xcrun xcstringstool sync "$catalog" --stringsdata "$work"/local/*.stringsdata "$work"/store/*.stringsdata
python3 - "$catalog" Resources/LocalizationRuntimeKeys.txt <<'PY'
import json, sys
catalog, keys_file = sys.argv[1], sys.argv[2]
data = json.load(open(catalog))
# Drop strings that no longer exist in the code (xcstringstool only marks them stale).
data["strings"] = {k: v for k, v in data["strings"].items() if v.get("extractionState") != "stale"}
for key in (line.rstrip("\n") for line in open(keys_file)):
    if key and not key.startswith("#"):
        entry = data["strings"].setdefault(key, {})
        entry["extractionState"] = "manual"
json.dump(data, open(catalog, "w"), ensure_ascii=False, indent=2, sort_keys=True)
open(catalog, "a").write("\n")
PY
echo "$(python3 -c "import json;print(len(json.load(open('$catalog'))['strings']))") keys in $catalog"
