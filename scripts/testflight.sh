#!/usr/bin/env bash
# Archive Pincer with App Store signing and upload it to TestFlight.
# Usage: scripts/testflight.sh ios|macos
#
# Expects the Apple Distribution (and, for macOS, Mac Installer Distribution) identities in a
# keychain on the search list and the *_AppStore_CI profiles installed. CI sets these up from
# repository secrets; see .github/workflows/testflight.yml.
#
# Environment:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH  App Store Connect API key (needed to upload)
#   BUILD_NUMBER                             CFBundleVersion (default: seconds since epoch)
#   UPLOAD=0                                 Export the signed .ipa/.pkg instead of uploading
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:?usage: $0 ios|macos}"
TEAM_ID="E4Y97NXBXG"
case "$PLATFORM" in
  ios)   SCHEME=Pincer-iOS;   DESTINATION="generic/platform=iOS";   BUNDLE_ID=chat.pincer.ios; PROFILE=Pincer_iOS_AppStore_CI
         EXTRA_PROFILES="<key>chat.pincer.ios.notifications</key><string>Pincer_iOS_Notifications_AppStore_CI</string>" ;;
  macos) SCHEME=Pincer-macOS; DESTINATION="generic/platform=macOS"; BUNDLE_ID=chat.pincer.mac; PROFILE=Pincer_macOS_AppStore_CI ;;
  *) echo "unknown platform: $PLATFORM" >&2; exit 64 ;;
esac

EXTRA_PROFILES="${EXTRA_PROFILES:-}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"
OUT="build/testflight/$PLATFORM"
ARCHIVE="$OUT/$SCHEME.xcarchive"
rm -rf "$OUT" && mkdir -p "$OUT"

# Generate with App Store signing, then restore the regular (automatic signing) project on exit.
# (XcodeGen can't overwrite an existing xcshareddata folder, so clear it first.)
generate() { rm -rf Pincer.xcodeproj/xcshareddata; xcodegen generate --quiet; }
trap generate EXIT
PINCER_APP_STORE_SIGNING=YES generate

xcodebuild archive \
  -project Pincer.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | { command -v xcbeautify >/dev/null && xcbeautify || cat; }

DESTINATION_MODE=upload
[ "${UPLOAD:-1}" = 0 ] && DESTINATION_MODE=export

INSTALLER_KEY=""
[ "$PLATFORM" = macos ] && INSTALLER_KEY="  <key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION_MODE</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
$INSTALLER_KEY  <key>provisioningProfiles</key>
  <dict><key>$BUNDLE_ID</key><string>$PROFILE</string>$EXTRA_PROFILES</dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
PLIST

AUTH=()
if [ -n "${ASC_KEY_ID:-}" ]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" \
  ${AUTH[@]+"${AUTH[@]}"}

echo "✅ $SCHEME build $BUILD_NUMBER ($DESTINATION_MODE)"
