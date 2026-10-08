---
title: Releasing to TestFlight
description: How Pincer's macOS and iOS builds are signed and uploaded to TestFlight.
---

`.github/workflows/testflight.yml` archives both apps, signs them for the App Store, and uploads them to TestFlight.

## Running a release

Either:

- go to **Actions → TestFlight → Run workflow** and pick a platform, or run `gh workflow run testflight.yml -f platform=both` (or `ios`, `macos`), or
- push a `v*` tag, which uploads both.

Only the selected platforms start a runner.

Each build number is `<run number>.<attempt>`.

The upload workflow first requires a completed, successful **Tests** push run on
`main` for the exact commit being uploaded. Pending, failed, cancelled, skipped,
PR-only or older-commit checks do not authorize an upload. Wait for the main
checks to finish and rerun TestFlight if this gate fails.

## Signing

Signing uses manual App Store profiles through `project.appstore.yml`, which is only included when `PINCER_APP_STORE_SIGNING=YES`. `scripts/testflight.sh ios|macos` does the work and also runs locally. Use `UPLOAD=0` to export without uploading.

## Required secrets

| Secret | Contents |
| --- | --- |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key (the `.p8` is base64) |
| `DISTRIBUTION_P12`, `MAC_INSTALLER_P12`, `P12_PASSWORD` | Apple Distribution and Mac Installer Distribution certificates (base64 `.p12`) |
| `IOS_PROFILE`, `MACOS_PROFILE` | Base64 `Pincer_iOS_AppStore_CI` / `Pincer_macOS_AppStore_CI` provisioning profiles. The iOS app ID needs the Push Notifications capability. |
| `IOS_NOTIFICATIONS_PROFILE` | Base64 `Pincer_iOS_Notifications_AppStore_CI` profile for the `chat.pincer.ios.notifications` notification service extension |
| `IOS_SHARE_PROFILE`, `MACOS_SHARE_PROFILE` | Base64 `Pincer_iOS_Share_AppStore_CI` / `Pincer_macOS_Share_AppStore_CI` profiles for the Share extensions (`chat.pincer.ios.share`, `chat.pincer.mac.share`) |

The iOS app and Share extension profiles need the App Groups capability with `group.chat.pincer`. macOS uses the team-prefixed group `<TeamID>.chat.pincer`, which needs no portal setup. The shared Keychain group `<TeamID>.chat.pincer.shared` is covered by the default keychain entitlement.

:::caution
The certificates and profiles expire on **2027-09-25**. Renew them before then and update the secrets.
:::

## Notes for testers and App Review

Testers and App Review don't need a gateway. Paste this into TestFlight's **What to Test** and App Store Connect's **App Review Information → Notes**:

```text
Pincer is a client for a self-hosted OpenClaw Gateway. No account or server is needed to review it:
open the app and tap "Try the Demo" on the first screen (right under "Get Started"). It opens
straight to the chat list. The demo runs a simulated gateway entirely on the device, with sample
agents, chats, approvals and settings. Nothing leaves the device.
```

## Privacy manifests and release checks

`PrivacyInfo.xcprivacy` is copied into each app and extension. PincerKit and
PincerUI also ship their own SwiftPM resource manifests. The declarations cover
app preferences, shared App Group preferences, elapsed-time measurements, and
metadata for files in app-owned containers. They do not authorize fingerprinting.

Before archiving, `scripts/testflight.sh` validates the generated project's
Copy Bundle Resources phases. After archiving, it inspects the actual app, Share
extension, iOS notification extension and package resource bundles. Missing or
changed declarations fail the release before export/upload. These checks do not
replace Apple's archive privacy report or App Store privacy questionnaires.

Run `python3 scripts/test_release_privacy.py` for the omission/malformed-manifest
regressions, and `python3 scripts/check_release_privacy.py --project Pincer.xcodeproj`
to check XcodeGen output. PincerChecks includes the same regression harness in
its offline suite. Review API use when dependencies or persistence change.
