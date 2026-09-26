---
title: Building from source
description: Build Pincer for macOS and iOS, run the unit tests and self-checks, and find your way around the code.
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

Set your team, then run **Pincer-macOS** or **Pincer-iOS**. The Xcode-built macOS app is sandboxed. Xcode builds also include the Share extensions and, on iOS, the notification service extension. The SwiftPM bundle doesn't.

## Unit tests

`Tests/PincerKitTests` is a [Swift Testing](https://developer.apple.com/documentation/testing) suite for PincerKit:

- device signing and the connect handshake
- TLS pinning, URL policy and failure classification
- reconnect backoff and protocol frame decoding
- the transcript cache, message search matching and composer drafts
- sidebar grouping, slash commands and approvals

```sh
swift test              # run the suite
swift test --parallel   # run tests in parallel worker processes, as CI does
swift test --filter "Device identity"   # one suite or test by name
```

The tests are hermetic:

- They open no sockets and never touch the real Keychain, `UserDefaults.standard` or Application Support.
- Each test uses its own temporary folder and scratch defaults suite, and cleans them up afterwards.
- They don't need `PINCER_KEYCHAIN=memory`, and they can run alongside `PincerChecks` without either run affecting the other.

## Self-checks

`PincerChecks` is an executable harness that exercises the stores end to end. It complements the unit tests:

```sh
PINCER_KEYCHAIN=memory swift run PincerChecks          # offline checks
PINCER_KEYCHAIN=memory swift run PincerChecks --demo   # the built-in demo gateway
PINCER_KEYCHAIN=memory swift run PincerChecks --live ws://127.0.0.1:18789 dev-token
PINCER_KEYCHAIN=memory swift run -c release PincerChecks --perf   # message search at scale
PINCER_KEYCHAIN=memory swift run PincerChecks --live-no-usage ws://127.0.0.1:18790 dev-token   # mock started with MOCK_NO_USAGE=1 PORT=18790
```

| Mode | What it checks |
| --- | --- |
| no flag | Offline checks: identity, protocol models, stores, the transcript cache, message search and composer drafts. |
| `--demo` | The offline checks, then a full run against the in-process demo gateway, including sidebar navigation and message search. |
| `--live <url> <token>` | The offline checks, then an end-to-end run against a real or [mock](../mock-gateway/) gateway. |
| `--perf` | Builds a message search index over 20 synthetic chats of 20,000 messages each and checks build time, query time, memory and index size. Build it in release (`-c release`), since its time targets assume an optimized build. |
| `--live-no-usage <url> <token>` | The offline checks, then a run against a gateway without the usage methods (the mock with `MOCK_NO_USAGE=1`), checking that Usage reports them as unsupported. |

Each run sets its own `PINCER_DRAFTS_DIR`, `PINCER_CACHE_DIR` and scratch defaults suite, so concurrent runs don't share storage.

## Continuous integration

`.github/workflows/tests.yml` runs on every pull request and every push to `main`:

1. **Mock gateway selftest** (Ubuntu): `npm ci && npm run selftest` in `mock-gateway/`.
2. **Swift build and checks** (macOS, `PINCER_KEYCHAIN=memory`):
   - Restores the cached `.build` folder
   - `swift build --build-tests`, then `swift test --skip-build --parallel`
   - `PincerChecks`
   - `PincerChecks --demo` (with `PINCER_DEMO_DELAY_SCALE=0.2`) and `PincerChecks --live` against the mock (started just before), **at the same time**
   - `PincerChecks --live-no-usage` against a second mock started with `MOCK_NO_USAGE=1` on port 18790

CI passes `-Xswiftc -enable-incremental-file-hashing` to every `swift` command. Checkout gives every file a new modification time, so without it the restored build would recompile everything.

To reproduce CI locally, run the same commands. For the live step, start the mock first: see [Mock gateway](../mock-gateway/). Each check run keeps its drafts, transcript cache and saved gateways in its own scratch folders and defaults suites, so the demo and live runs can safely run at the same time.

## Environment variables

| Variable | Effect |
| --- | --- |
| `PINCER_KEYCHAIN=memory` | Keep identities and secrets in memory, so checks and dev runs never touch your real Keychain. |
| `PINCER_CACHE_DIR` | `off` disables the transcript cache and message search. A path moves both. |
| `PINCER_DRAFTS_DIR` | `off` disables saved composer drafts. A path moves them. |
| `PINCER_REQUEST_LOG` | A file path to log every request and the gateway's reply. |
| `PINCER_DEMO_DELAY_SCALE` | Multiplies the demo gateway's simulated streaming and tool delays. `0.2` runs the demo five times faster. `0` removes them entirely, but then the demo checks can't see the streaming phases. |

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
| `Apps/Shared` | Resources shared by both apps, including the layered app icon (`AppIcon.icon`) and the Info.plist keys that name the App Group and Keychain group. |
| `Apps/ShareExtension` | Share extensions for iOS and macOS: a view controller per platform plus the shared SwiftUI sheet. The logic lives in PincerKit. |
| `Apps/iOSNotificationService` | iOS notification service extension that decrypts relayed pushes. |
| `Design/AppIcon` | Flattened reference artwork for the app icon. |
| `Sources/PincerMacDev` | Dev entry point so SwiftPM alone can produce the macOS app. |
| `Sources/PincerChecks` | Self-checks, with optional demo and live end-to-end runs. |
| `Sources/PincerPush` | Web Push decryption (RFC 8291), per-gateway push keys and payload parsing, shared by the app and its notification service extension. |
| `push-relay/` | Zero-dependency Node relay from Gateway Web Push to APNs. See [Push notifications](../../guides/push-notifications/). |
| `Tests/PincerKitTests` | Unit tests for PincerKit (`swift test`). |
| `mock-gateway/` | Node mock of the Gateway protocol for offline development. |
| `website/` | This documentation site. |

## Known gaps

- iOS runs in the simulator (connect, sidebar, history) but hasn't been tried on a real device yet.
- Gateway Settings has been tested against the mock only.
