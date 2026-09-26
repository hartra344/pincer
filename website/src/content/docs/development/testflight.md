---
title: Releasing to TestFlight
description: How Pincer's macOS and iOS builds are signed and uploaded to TestFlight.
---

`.github/workflows/testflight.yml` archives both apps, signs them for the App Store, and uploads them to TestFlight.

## Running a release

Either:

- go to **Actions → TestFlight → Run workflow** and pick a platform, or
- push a `v*` tag.

Each build number is `<run number>.<attempt>`.

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
