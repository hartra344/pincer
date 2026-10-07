#!/usr/bin/env bash
# Launch CPU smoke check for the macOS app (#119: the menu bar item pinned the main thread at launch).
# Launches a built Pincer.app directly, lets it settle, samples its CPU and fails above a threshold.
#
# Usage: scripts/check-launch-cpu.sh [options] [path/to/Pincer.app | path/to/PincerMacDev]
#   --menu-bar on|off   pincer.menuBar.enabled for this run (default: off)
#   --demo              start with only the built-in demo gateway saved (connected at launch)
#   --threshold N       fail when the average %CPU is above N (default: 5; the target is ~2% idle,
#                       the rest is headroom for noise. The #119 loop sits at ~100%)
#   --settle S          seconds to wait after launch before sampling (default: 8)
#   --samples N         CPU samples, one per second (default: 10)
#   --bundle-id ID      defaults domain to use (default: chat.pincer.cpucheck, see below)
#
# The app defaults to build/Pincer.app (`scripts/bundle-mac.sh release`). To leave your own
# preferences, saved gateways and Keychain alone, it runs a copy under its own bundle id
# (build/Pincer CPU Check.app, chat.pincer.cpucheck).
# Pass --bundle-id chat.pincer.mac to run the app as built; the settings it changes are restored.
# Every run, including chat.pincer.mac, sets PINCER_KEYCHAIN=memory (no Keychain access or password
# prompts) and PINCER_CACHE_DIR=off / PINCER_DRAFTS_DIR=off (no transcript cache or drafts on disk).
# A bare PincerMacDev binary (e.g. `$(swift build --show-bin-path)/PincerMacDev`) is wrapped in a
# minimal bundle first, so a debug build can be checked without scripts/bundle-mac.sh.
# macOS only. Example: scripts/bundle-mac.sh release && scripts/check-launch-cpu.sh --menu-bar on --demo
set -euo pipefail
cd "$(dirname "$0")/.."

MENU_BAR=off
DEMO=0
THRESHOLD=5
SETTLE=8
SAMPLES=10
BUNDLE_ID=chat.pincer.cpucheck
APP=build/Pincer.app
while [ $# -gt 0 ]; do
  case "$1" in
    --menu-bar) MENU_BAR="$2"; shift 2 ;;
    --demo) DEMO=1; shift ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) APP="$1"; shift ;;
  esac
done
case "$MENU_BAR" in on|true|1) MENU_BAR=true ;; off|false|0) MENU_BAR=false ;; *) echo "--menu-bar takes on or off" >&2; exit 2 ;; esac
[ "$(uname)" = Darwin ] || { echo "macOS only" >&2; exit 2; }
if [ -f "$APP" ] && [ -x "$APP" ]; then
  WRAPPED="build/Pincer CPU Check Binary.app"
  rm -rf "$WRAPPED"
  mkdir -p "$WRAPPED/Contents/MacOS" "$WRAPPED/Contents/Resources"
  cp "$APP" "$WRAPPED/Contents/MacOS/Pincer"
  # SwiftPM resource bundles (PincerUI's String Catalog); `Bundle.module` looks in Contents/Resources.
  for bundle in "$(dirname "$APP")"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$WRAPPED/Contents/Resources/"
  done
  cat > "$WRAPPED/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>chat.pincer.mac</string>
  <key>CFBundleName</key><string>Pincer</string>
  <key>CFBundleExecutable</key><string>Pincer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
  APP="$WRAPPED"
fi
[ -d "$APP" ] || { echo "no app at $APP (build it with scripts/bundle-mac.sh release)" >&2; exit 2; }

BUILT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ "$BUNDLE_ID" != "$BUILT_ID" ]; then
  # A copy with its own bundle id, so its defaults domain is separate from the real app's.
  COPY="build/Pincer CPU Check.app"
  rm -rf "$COPY"
  cp -R "$APP" "$COPY"
  PLIST="$COPY/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName Pincer CPU Check" "$PLIST"
  # No App Group or shared Keychain group: those belong to the real app.
  /usr/libexec/PlistBuddy -c "Delete :PincerAppGroup" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :PincerKeychainGroup" "$PLIST" 2>/dev/null || true
  codesign --force --sign - --options runtime "$COPY" >/dev/null 2>&1
  APP="$COPY"
fi
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

# Snapshot the whole defaults domain first and put it back afterwards (or remove it if it was new),
# so the menu bar setting, the demo profile and anything the app wrote while running are undone.
STATE_DIR="$(pwd)/build/cpu-check-state"
mkdir -p "$STATE_DIR"
SNAPSHOT="$STATE_DIR/$BUNDLE_ID.plist"
if defaults export "$BUNDLE_ID" "$SNAPSHOT" 2>/dev/null && [ "$(plutil -p "$SNAPSHOT" 2>/dev/null)" != "{}" ]; then
  HAD_DOMAIN=1
else
  HAD_DOMAIN=0
fi

PID=""
cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
    kill -9 "$PID" 2>/dev/null || true
  fi
  if [ "$HAD_DOMAIN" = 1 ]; then
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    defaults import "$BUNDLE_ID" "$SNAPSHOT"
  else
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  rm -f "$SNAPSHOT"
}
trap cleanup EXIT INT TERM

defaults write "$BUNDLE_ID" pincer.menuBar.enabled -bool "$MENU_BAR"
if [ "$DEMO" = 1 ]; then
  # Only the built-in demo is saved, so it connects at launch without a network.
  DEMO_ID="$(uuidgen)"
  PROFILES="[{\"id\":\"$DEMO_ID\",\"name\":\"Demo\",\"url\":\"demo://pincer\",\"authMode\":\"none\",\"access\":\"standard\"}]"
  defaults write "$BUNDLE_ID" pincer.gatewayProfiles.v1 -data "$(printf '%s' "$PROFILES" | xxd -p | tr -d '\n')"
  defaults write "$BUNDLE_ID" pincer.selectedGateway -string "$DEMO_ID"
fi

# Every launch path: an in-memory Keychain (never a Keychain password prompt, as in CI) and no
# transcript cache or drafts on disk, even with --bundle-id chat.pincer.mac.
export PINCER_KEYCHAIN=memory PINCER_CACHE_DIR=off PINCER_DRAFTS_DIR=off
"$BIN" >"$STATE_DIR/app.log" 2>&1 &
PID=$!
echo "Launched $APP (pid $PID, menu bar $MENU_BAR$([ "$DEMO" = 1 ] && echo ', demo'))"
sleep "$SETTLE"
kill -0 "$PID" 2>/dev/null || { echo "✗ the app exited during launch"; cat "$STATE_DIR/app.log"; exit 1; }
if [ "$DEMO" = 1 ]; then
  # Written once the demo connected and synced its health dismissals with users.prefs.
  if [ "$(defaults read "$BUNDLE_ID" "pincer.healthDismissalsSynced.$DEMO_ID" 2>/dev/null)" = 1 ]; then
    echo "Demo connected"
  else
    echo "✗ the demo gateway didn't connect"
    exit 1
  fi
fi

readings=()
for _ in $(seq 1 "$SAMPLES"); do
  cpu="$(ps -o %cpu= -p "$PID" | tr -d ' ')"
  [ -n "$cpu" ] || { echo "✗ the app exited while sampling"; exit 1; }
  readings+=("$cpu")
  sleep 1
done
AVERAGE="$(printf '%s\n' "${readings[@]}" | awk '{ sum += $1 } END { printf "%.1f", sum / NR }')"
echo "CPU samples: ${readings[*]} → average ${AVERAGE}% (threshold ${THRESHOLD}%)"
if awk -v a="$AVERAGE" -v t="$THRESHOLD" 'BEGIN { exit !(a > t) }'; then
  echo "✗ launch CPU too high: the app is probably stuck in an update loop"
  exit 1
fi
echo "✓ launch CPU ok"
