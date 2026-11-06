#!/usr/bin/env bash
# #1097: captures the compact iPhone chat header over dense transcript text in light and dark mode.
#   scripts/capture-compact-header.sh <label>
# Writes light-*.png, dark-*.png (+ *-top.png crops of the top 45%) and frames.txt to
# ${PINCER_SHOT_ROOT:-.build/compact-header-shots}/<label>/. Diagnostic only: nothing is compared.
# PINCER_SIM_UDID picks the simulator (default: iPhone 17 Pro), PINCER_DD the derived data path.
set -euo pipefail
label="${1:?usage: $0 <label>}"
cd "$(dirname "$0")/.."
root="$PWD"
udid="${PINCER_SIM_UDID:-217D5F25-60D8-4E18-BE55-6AD7A1ECF8E2}"
out="${PINCER_SHOT_ROOT:-$root/.build/compact-header-shots}/$label"
dd="${PINCER_DD:-$root/.build/pincer1097-dd}"

grep -qs CompactChatHeaderFadeUITests Pincer.xcodeproj/project.pbxproj && [ Pincer.xcodeproj/project.pbxproj -nt project.yml ] \
    || xcodegen generate --quiet
xcrun simctl bootstatus "$udid" -b > /dev/null
rm -rf "$out" && mkdir -p "$out"

TEST_RUNNER_PINCER_SHOT_DIR="$out" xcodebuild test -quiet -project Pincer.xcodeproj -scheme PincerAppUITests-iOS \
    -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:PincerAppUITests-iOS/CompactChatHeaderFadeUITests/testCaptureCompactHeaderFade \
    -derivedDataPath "$dd" -resultBundlePath "$out/result.xcresult" CODE_SIGNING_ALLOWED=NO

for png in "$out"/light-*.png "$out"/dark-*.png; do
    [ -e "$png" ] || { echo "no screenshots in $out" >&2; exit 1; }
    h=$(sips -g pixelHeight "$png" | awk '/pixelHeight/ {print $2}')
    w=$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')
    sips --cropToHeightWidth $((h * 45 / 100)) "$w" --cropOffset 1 0 "$png" --out "${png%.png}-top.png" > /dev/null
done
ls -1 "$out"/*.png
