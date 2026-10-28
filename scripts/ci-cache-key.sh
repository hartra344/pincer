#!/bin/sh
# path… → `key=<sha256>` for $GITHUB_OUTPUT: a cache key over the tracked files under those paths.
# It hashes the blob ids already in git's index, so it's instant. `hashFiles()` reads every file and
# timed out after 120s on a runner busy booting a simulator (main run 39990000894).
set -eu
[ "$#" -gt 0 ] || { echo "usage: $0 path…" >&2; exit 2; }
listing=$(git ls-files -s -- "$@")
[ -n "$listing" ] || { echo "no tracked files under: $*" >&2; exit 1; }
printf 'key=%s\n' "$(printf '%s\n' "$listing" | shasum -a 256 | cut -d' ' -f1)"
