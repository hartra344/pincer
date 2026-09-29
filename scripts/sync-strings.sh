#!/usr/bin/env bash
# Regenerate PincerUI's String Catalog (Sources/PincerUI/Resources/Localizable.xcstrings) from source.
# Usage: scripts/sync-strings.sh [--skip-build]
#
# Builds the PincerUI package target for macOS and the iOS Simulator with the compiler's string
# extraction on (SWIFT_EMIT_LOC_STRINGS), then merges the extracted strings of every PincerUI file
# that looks strings up in its own bundle (`bundle: .module` or `L("…")`) into the catalog with
# `xcstringstool sync`. Each key gets an English value equal to the key, and keys with no letters
# (pure format strings such as "%@ %@") are dropped since there's nothing to translate.
# Syncs into the existing catalog, so translations and comments are kept; keys no longer in the code
# (marked stale by xcstringstool) are removed.
# --skip-build reuses the extraction output of a previous run in build/strings.
set -euo pipefail
cd "$(dirname "$0")/.."
CATALOG="Sources/PincerUI/Resources/Localizable.xcstrings"
DERIVED="build/strings"

if [[ "${1:-}" != "--skip-build" ]]; then
  for destination in "generic/platform=macOS" "generic/platform=iOS Simulator"; do
    xcodebuild -scheme PincerUI -destination "$destination" -derivedDataPath "$DERIVED" \
      SWIFT_EMIT_LOC_STRINGS=YES build -quiet
  done
fi

args=()
while IFS= read -r source; do
  name="$(basename "$source" .swift)"
  while IFS= read -r data; do args+=(--stringsdata "$data"); done \
    < <(find "$DERIVED/Build/Intermediates.noindex" -path "*PincerUI*" -path "*/arm64/*" -name "$name.stringsdata")
done < <(grep -lE 'bundle: \.module|[^A-Za-z]L\("' Sources/PincerUI/*.swift)
if [[ ${#args[@]} -eq 0 ]]; then
  echo "No .stringsdata found under $DERIVED; run without --skip-build." >&2
  exit 1
fi

xcrun xcstringstool sync "$CATALOG" "${args[@]}"

python3 - "$CATALOG" <<'PY'
import json, re, sys
path = sys.argv[1]
catalog = json.load(open(path))
strings = {}
for key, entry in sorted(catalog["strings"].items(), key=lambda item: item[0].lower()):
    if not re.search(r"[A-Za-z]", re.sub(r"%(\d+\$)?(lld|ld|d|@|lf|f)", "", key)):
        continue
    if entry.get("extractionState") == "stale":
        continue
    entry.pop("extractionState", None)
    english = entry.setdefault("localizations", {}).setdefault("en", {"stringUnit": {"value": key}})
    if "stringUnit" in english:
        english["stringUnit"]["state"] = "translated"
    strings[key] = entry
catalog["strings"] = strings
with open(path, "w") as out:
    json.dump(catalog, out, indent=2, ensure_ascii=False, sort_keys=True)
    out.write("\n")
print(f"{path}: {len(strings)} keys")
PY
