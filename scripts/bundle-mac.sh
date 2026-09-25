#!/usr/bin/env bash
# Build Pincer.app from the SwiftPM package without an Xcode project.
# Usage: scripts/bundle-mac.sh [debug|release]   → build/Pincer.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product PincerMacDev
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PincerMacDev"
APP="build/Pincer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pincer"
# SwiftPM records the deployment target as the SDK version, so macOS would run the app in its
# pre-26 compatibility look (no Liquid Glass). Stamp the SDK it was actually built with.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos 15.0 "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/Pincer" "$APP/Contents/MacOS/Pincer"
# App icon: reuse the macOS PNGs from the asset catalog (regenerate with scripts/make-icons.swift).
ICONSET="build/Pincer.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
cp Apps/Shared/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Pincer.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>chat.pincer.mac</string>
  <key>CFBundleName</key><string>Pincer</string>
  <key>CFBundleDisplayName</key><string>Pincer</string>
  <key>CFBundleExecutable</key><string>Pincer</string>
  <key>CFBundleIconFile</key><string>Pincer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# Signed with only the network-client entitlement (no sandbox so local runs work).
# Prefers an Apple Development identity: a stable signature keeps Keychain access across rebuilds,
# whereas ad-hoc signatures change every build and re-prompt for the Keychain.
IDENTITY="${PINCER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
cat > build/dev.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.network.client</key><true/></dict></plist>
ENT
codesign --force --sign "$IDENTITY" --entitlements build/dev.entitlements --options runtime "$APP"
echo "Built $APP (signed: ${IDENTITY/#-/ad-hoc})"
