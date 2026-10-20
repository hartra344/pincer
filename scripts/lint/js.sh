#!/usr/bin/env bash
# JS lint gates: jscpd duplication ratchet (whole repo) + knip (mock-gateway, push-relay).
#   scripts/lint/js.sh            run the gates
#   scripts/lint/js.sh --update   also rewrite the jscpd baseline instead of failing on it
# Needs Node >= 20.19; installs scripts/lint/node_modules with `npm ci` when missing.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../.."

if [[ ! -x "$here/node_modules/.bin/knip" || ! -x "$here/node_modules/.bin/jscpd" ]]; then
  npm ci --prefix "$here" --no-audit --no-fund --silent || { echo "npm ci failed in scripts/lint" >&2; exit 2; }
fi

status=0

echo "== jscpd (duplication ratchet)"
node "$here/jscpd-gate.mjs" "$@" || status=1

# knip runs without node_modules in the target dirs; its configs live in scripts/lint.
# Unused exports only used in their own file are ignored (see the configs for reasons).
for dir in mock-gateway push-relay; do
  echo "== knip ($dir)"
  if ! "$here/node_modules/.bin/knip" --directory "$dir" --config "$here/knip.$dir.jsonc" --no-progress; then
    echo "knip found unused files/exports/dependencies in $dir/. Remove them (or use them); see scripts/lint/knip.$dir.jsonc." >&2
    status=1
  fi
done

exit $status
