#!/usr/bin/env bash
# Build a separate app for documentation captures. Never launch the ordinary dev bundle for captures.
set -euo pipefail
cd "$(dirname "$0")/.."
PINCER_SIGN_IDENTITY=- scripts/bundle-mac.sh "${1:-debug}"
APP="build/Pincer Documentation.app"
# Only replace this generated bundle, not the user's installed app or its preferences.
rm -rf "$APP"
cp -R build/Pincer.app "$APP"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
info['CFBundleIdentifier'] = 'chat.pincer.documentation'
info['CFBundleName'] = 'Pincer Documentation'
info['CFBundleDisplayName'] = 'Pincer Documentation'
info.pop('PincerAppGroup', None)
info.pop('PincerKeychainGroup', None)
info['LSEnvironment'] = {
    'PINCER_KEYCHAIN': 'memory',
    'PINCER_CACHE_DIR': 'off',
    'PINCER_DRAFTS_DIR': 'off',
}
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
codesign --force --sign - --entitlements build/dev.entitlements --options runtime "$APP"
# These settings belong exclusively to the documentation bundle.
defaults write chat.pincer.documentation pincer.ownerName -string Alex
defaults write chat.pincer.documentation pincer.thinkingDisplay -string all
defaults write chat.pincer.documentation pincer.theme.mode -string light
printf 'Capture app prepared: %s\nChoose Try the Demo. Never add a real gateway to this app.\n' "$PWD/$APP"
