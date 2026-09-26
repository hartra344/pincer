---
title: Building from source
description: Build Pincer for macOS and iOS, run the self-checks, and find your way around the code.
---

## Requirements

- A current **Xcode** with Swift 6 and the macOS 15 / iOS 18 SDKs or later.
- The Xcode license accepted: `sudo xcodebuild -license accept`.

The SwiftUI macros only ship inside Xcode.app, so the Command Line Tools alone won't build the UI.

## Quick build with SwiftPM

```sh
swift build                      # PincerKit, PincerUI, dev app, checks
scripts/bundle-mac.sh release    # -> build/Pincer.app (ad-hoc signed)
open build/Pincer.app
```

## Signed builds with Xcode

Generate the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open Pincer.xcodeproj
```

Set your team, then run **Pincer-macOS** or **Pincer-iOS**. The Xcode-built macOS app is sandboxed.

## Self-checks

```sh
PINCER_KEYCHAIN=memory swift run PincerChecks
PINCER_KEYCHAIN=memory swift run PincerChecks --live ws://127.0.0.1:18789 dev-token
PINCER_KEYCHAIN=memory swift run PincerChecks --demo   # the built-in demo
```

`--live` runs an end-to-end check against a gateway, such as the [mock gateway](../mock-gateway/).

## Environment variables

| Variable | Effect |
| --- | --- |
| `PINCER_KEYCHAIN=memory` | Keep identities and secrets in memory, so checks and dev runs never touch your real Keychain. |
| `PINCER_CACHE_DIR` | `off` disables the transcript cache. A path moves it. |
| `PINCER_REQUEST_LOG` | A file path to log every request and the gateway's reply. |

They work for the app too:

```sh
open --env PINCER_KEYCHAIN=memory build/Pincer.app
open --env PINCER_REQUEST_LOG=/tmp/pincer.log build/Pincer.app
```

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/PincerKit` | Protocol client (handshake, signing, reconnect, TLS pinning), models, and the observable stores. No UI. |
| `Sources/PincerUI` | Shared UI for macOS and iOS. The shell is SwiftUI. The transcript and sidebar are native for performance: `NSTableView`/`NSOutlineView` on macOS and `UICollectionView` on iOS, with Markdown laid out once with TextKit. |
| `Apps/macOS`, `Apps/iOS` | `@main` app shells used by the Xcode project. |
| `Apps/Shared` | Resources shared by both apps, including the layered app icon (`AppIcon.icon`). |
| `Design/AppIcon` | Flattened reference artwork for the app icon. |
| `Sources/PincerMacDev` | Dev entry point so SwiftPM alone can produce the macOS app. |
| `Sources/PincerChecks` | Self-checks, with an optional live end-to-end run. |
| `mock-gateway/` | Node mock of the Gateway protocol for offline development. |
| `website/` | This documentation site. |

## Known gaps

- iOS runs in the simulator (connect, sidebar, history) but hasn't been tried on a real device yet.
- Gateway Settings has been tested against the mock only.
