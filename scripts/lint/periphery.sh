#!/usr/bin/env bash
# Swift dead-code gate: Periphery over the SwiftPM index store, then scripts/lint/periphery-gate.mjs.
#   scripts/lint/periphery.sh [--update] [--skip-build] [swift build flags...]
# --update rewrites scripts/lint/periphery-baseline.json instead of failing (fill in each reason).
# --skip-build scans the index store of the last `swift build --build-tests`.
# PERIPHERY_BIN overrides the pinned Periphery binary (downloaded to ~/.cache/pincer-lint otherwise).
# Builds with the same flags as a plain `swift build --build-tests`, so it reuses your local .build.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../.."

PERIPHERY_VERSION=3.8.0
PERIPHERY_SHA256=a9c7bfb1483dde1f4b660bc64183161fde3b519b7392add51ec8fe8b846cf494

update=() build=true swift_flags=()
for arg in "$@"; do
  case "$arg" in
    --update) update=(--update) ;;
    --skip-build) build=false ;;
    *) swift_flags+=("$arg") ;;
  esac
done

if [[ -z "${PERIPHERY_BIN:-}" ]]; then
  cache="${PERIPHERY_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pincer-lint}/periphery-$PERIPHERY_VERSION"
  PERIPHERY_BIN="$cache/periphery-$PERIPHERY_VERSION.artifactbundle/periphery-$PERIPHERY_VERSION-macos/bin/periphery"
  if [[ ! -x "$PERIPHERY_BIN" ]]; then
    echo "Downloading Periphery $PERIPHERY_VERSION"
    mkdir -p "$cache"
    zip="$cache/periphery.zip"
    curl -fsSL "https://github.com/peripheryapp/periphery/releases/download/$PERIPHERY_VERSION/periphery-$PERIPHERY_VERSION.artifactbundle.zip" -o "$zip"
    echo "$PERIPHERY_SHA256  $zip" | shasum -a 256 -c - >/dev/null
    unzip -qo "$zip" -d "$cache"
    rm "$zip"
  fi
fi

if $build; then
  echo "== swift build --build-tests (index store for Periphery)"
  swift build --build-tests --enable-index-store ${swift_flags[@]+"${swift_flags[@]}"}
fi
store="$(swift build --show-bin-path ${swift_flags[@]+"${swift_flags[@]}"})/index/store"
[[ -d "$store" ]] || { echo "No index store at $store; run without --skip-build." >&2; exit 2; }

echo "== Periphery $PERIPHERY_VERSION"
results="$(mktemp -t periphery.XXXXXX)"
trap 'rm -f "$results"' EXIT
"$PERIPHERY_BIN" scan --config .periphery.yml --skip-build --index-store-path "$store" \
  --format json --quiet --write-results "$results" >/dev/null
node "$here/periphery-gate.mjs" "$results" ${update[@]+"${update[@]}"}
