#!/usr/bin/env bash
# Build Pincer.app from the SwiftPM package without an Xcode project.
# Usage: scripts/bundle-mac.sh [debug|release]   → build/Pincer.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product PincerMacDev
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PincerMacDev"
BASE_BUNDLE_ID="chat.pincer.mac"
BUNDLE_ID="$BASE_BUNDLE_ID"
DEV_SUFFIX=""
if [ -n "${PINCER_DEV_NAMESPACE:-}" ]; then
  # Match DevNamespace.sanitize's Unicode lowercasing, scalar replacement, and cap order.
  DEV_NAMESPACE="$(python3 -c 'import os, re; name = re.sub("[^a-z0-9]+", "-", os.environ["PINCER_DEV_NAMESPACE"].lower()); print(name[:24].strip("-"))')"
  if [ -n "$DEV_NAMESPACE" ]; then
    DEV_SUFFIX=".dev-$DEV_NAMESPACE"
    BUNDLE_ID="$BASE_BUNDLE_ID$DEV_SUFFIX"
  fi
fi
BUILD_ROOT="${PINCER_BUNDLE_ROOT:-build}"
APP="$BUILD_ROOT/Pincer.app"
mkdir -p "$BUILD_ROOT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pincer"
# SwiftPM resource bundles (e.g. PincerUI's String Catalog); `Bundle.module` looks in Contents/Resources.
for bundle in "$(dirname "$BIN")"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# SwiftPM records the deployment target as the SDK version, so macOS would run the app in its
# pre-26 compatibility look (no Liquid Glass). Stamp the SDK it was actually built with.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos 15.0 "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/Pincer" "$APP/Contents/MacOS/Pincer"
# App icon: compile the layered Icon Composer file. Assets.car carries the Liquid Glass icon with its
# dark/clear/tinted appearances (macOS 26+); AppIcon.icns is the flat fallback for macOS 15.
xcrun actool Apps/Shared/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$BUILD_ROOT/icon-partial.plist" --output-format human-readable-text >/dev/null
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  ${DEV_SUFFIX:+<key>PincerDevSuffix</key><string>$DEV_SUFFIX</string>}
  <key>CFBundleName</key><string>Pincer</string>
  <key>CFBundleDisplayName</key><string>Pincer</string>
  <key>CFBundleExecutable</key><string>Pincer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Dictate messages to your agents.</string>
  <key>NSLocationUsageDescription</key><string>Share your device location as context for your agent, separate from message text, only when you enable location sharing.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Turn what you say into text in the message box. Pincer never sends it on its own.</string>
</dict>
</plist>
PLIST
# Signed with the network-client and microphone (Dictation) entitlements (no sandbox so local runs work).
# Prefers an Apple Development identity: a stable signature keeps Keychain access across rebuilds,
# whereas ad-hoc signatures change every build and re-prompt for the Keychain.
IDENTITY="${PINCER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
cat > "$BUILD_ROOT/dev.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.network.client</key><true/><key>com.apple.security.device.audio-input</key><true/></dict></plist>
ENT
codesign --force --sign "$IDENTITY" --entitlements "$BUILD_ROOT/dev.entitlements" --options runtime "$APP"
echo "Built $APP (signed: ${IDENTITY/#-/ad-hoc})"
