#!/usr/bin/env bash
# Run the lint gates locally: Swift dead code (Periphery) and JS dead code + duplication (knip, jscpd).
#   scripts/lint.sh                    # every gate
#   scripts/lint.sh periphery          # one gate: periphery | js
#   scripts/lint.sh --update-baselines # rewrite the baselines instead of failing
# Extra flags after `periphery` go to scripts/lint/periphery.sh (e.g. --skip-build).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

update=() gates=() rest=()
for arg in "$@"; do
  case "$arg" in
    --update-baselines) update=(--update) ;;
    periphery|js) gates+=("$arg") ;;
    *) rest+=("$arg") ;;
  esac
done
[[ ${#gates[@]} -gt 0 ]] || gates=(js periphery)

status=0
for gate in "${gates[@]}"; do
  echo "==== $gate"
  case "$gate" in
    periphery) "$here/lint/periphery.sh" ${update[@]+"${update[@]}"} ${rest[@]+"${rest[@]}"} || status=1 ;;
    js) "$here/lint/js.sh" ${update[@]+"${update[@]}"} || status=1 ;;
  esac
done
exit $status
