#!/usr/bin/env bash
# CI: picks an available iPhone simulator, prints `udid=<id>` for $GITHUB_OUTPUT and boots it in the
# background so the boot overlaps the build. Wait for it with `xcrun simctl bootstatus <udid> -b`.
# --warm-webkit also opens Safari once booted, so WebKit's first, slow launch happens during the build.
set -euo pipefail
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
phones = [d for runtime, devices in json.load(sys.stdin)["devices"].items() if "iOS" in runtime
          for d in devices if d["name"].startswith("iPhone") and d["isAvailable"]]
print(phones[0]["udid"] if phones else "")')"
[ -n "$UDID" ] || { echo "No available iPhone simulator" >&2; exit 1; }
warm=""
[ "${1:-}" = --warm-webkit ] && warm=1
(
    xcrun simctl bootstatus "$UDID" -b
    [ -z "$warm" ] || xcrun simctl openurl "$UDID" "data:text/html,<p>warm</p>"
) > "${RUNNER_TEMP:-/tmp}/simulator-boot.log" 2>&1 < /dev/null &
echo "udid=$UDID"
