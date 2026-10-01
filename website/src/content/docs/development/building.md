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

## Localization

UI strings live in `Sources/PincerUI/Resources/Localizable.xcstrings` and are looked up with `bundle: .module`. See [Localization](../localization/).

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
- Secrets always use an in-memory store: `Keychain` detects the test runner, so no `PINCER_KEYCHAIN=memory` is needed, and a test fails if any real Keychain call happens.
- They can run alongside `PincerChecks` without either run affecting the other.

`Tests/PincerUITests` covers the shared transcript UI on macOS: Markdown caching, how a streaming reply is split and drawn, and a streaming performance probe. The probe streams a synthetic reply to 2, 10 and 25 KB and prints the main-thread milliseconds per token and the slowest update as a table:

```sh
swift test --filter StreamingProbe
```

While a reply streams, the transcript updates about 30 times a second. Finished paragraphs are laid out once and only the paragraph being written is measured again, so the cost of each update stays flat as the reply grows.

## Self-checks

The live core paging check uses a separate uncached, headless chat store, so the newest-page and older-page assertions remain independent of background prefetch and already-open transcripts.

`PincerChecks` is an executable harness that exercises the stores end to end. It complements the unit tests:

```sh
swift run PincerChecks          # offline (unit) checks
swift run PincerChecks --demo   # the built-in demo gateway (--demo-core + --demo-extras)
swift run PincerChecks --live-core ws://127.0.0.1:18789 dev-token
swift run PincerChecks --live-extras ws://127.0.0.1:18789 dev-token
swift run -c release PincerChecks --perf   # message search at scale
swift run PincerChecks --live-no-usage ws://127.0.0.1:18790 dev-token   # mock started with MOCK_NO_USAGE=1 PORT=18790
swift run PincerChecks --live-no-reply-to ws://127.0.0.1:18791 dev-token   # mock started with MOCK_NO_REPLY_TO=1 PORT=18791
```

A mode flag picks the mode, and each mode runs only its own suite: a mode flag doesn't also run the offline checks. Which sections belong to which suite is listed in `Sources/PincerChecks/Registry.swift` (see [Contributing](../contributing/)). `scripts/run-checks.sh` runs every mode side by side.

| Mode | What it checks |
| --- | --- |
| no flag | Offline checks: identity, protocol models, stores, the transcript cache, message search and composer drafts. |
| `--demo` | Both halves of the demo run, `--demo-core` then `--demo-extras`. |
| `--demo-core` / `--demo-extras` | The two halves of `--demo`, so they can run side by side. A full run against the in-process demo gateway, including sidebar navigation and message search. |
| `--live <url> <token>` | Both halves of the end-to-end run, `--live-core` then `--live-extras`, against a real or [mock](../mock-gateway/) gateway. |
| `--live-core <url> <token>` / `--live-extras <url> <token>` | The two halves of `--live`, so they can run side by side against separate, fresh mocks. `--live-core` is the main end-to-end run; `--live-extras` covers Quick Capture, replies and reactions, the transcript cache, the setup wizard, deep links, tool diffs and avatars. |
| `--perf` | Builds a message search index over 20 synthetic chats of 20,000 messages each and checks build time, query time, memory and index size. Build it in release (`-c release`), since its time targets assume an optimized build. |
| `--live-no-usage <url> <token>` | A run against a gateway without the usage methods (the mock with `MOCK_NO_USAGE=1`), checking that Usage reports them as unsupported. |
| `--live-no-reply-to <url> <token>` | A run against a gateway that rejects `chat.send`'s `replyToId` (the mock with `MOCK_NO_REPLY_TO=1`), checking that replies fall back to quoting the original. |

Add `--skip-intent-checks` to the plain run to leave out the Shortcuts & Siri offline checks, which wait on real reply timeouts (about 15 seconds).

Add `--skip-perf-budgets` to any mode to report the offline perf smoke timings (message index build, query and append) without enforcing their budgets. Only clearly broken timings, such as a selective query over 1 second, still fail. Use it when other work shares the CPU. `--perf-smoke` runs only the perf smoke, with its budgets enforced.

Each run sets its own `PINCER_DRAFTS_DIR`, `PINCER_CACHE_DIR` and scratch defaults suite, so concurrent runs don't share storage. It also keeps every secret in memory, so it never touches or prompts for your real Keychain (no `PINCER_KEYCHAIN=memory` needed), and it fails if any real Keychain call happens.

## Launch CPU check

`scripts/check-launch-cpu.sh` launches a built Mac app, waits for it to settle, samples its CPU and fails if it isn't idle. It catches launch loops like the menu bar freeze in #119:

```sh
scripts/bundle-mac.sh release
scripts/check-launch-cpu.sh --menu-bar on --demo
```

`--menu-bar on|off` sets the menu bar item for the run, and `--demo` saves only the built-in demo gateway, so it connects at launch. By default the script runs a copy of the app under its own bundle id with an in-memory Keychain, and it restores that bundle's defaults afterwards, so your own settings and gateways aren't touched. Run `scripts/check-launch-cpu.sh --help` for the other options.

CI runs it every night (`.github/workflows/launch-cpu.yml`), with the menu bar on and the demo gateway and again with the menu bar off, against a release build of `main`. The nightly run is skipped when `main` has no commits from the last day. The workflow also runs on pull requests that change the check or `scripts/bundle-mac.sh`, and from **Actions → Launch CPU → Run workflow**.

## Continuous integration

`.github/workflows/tests.yml` runs on every pull request and every push to `main`:

1. **Detect changes** (Ubuntu): lists the changed files. If they're all docs (`website/`, `docs/`, top-level Markdown files or `LICENSE`), the next two jobs are skipped, which counts as passing. Anything else, including workflows, `Package.swift`, `project.yml`, `scripts/`, `mock-gateway/` and the sources, runs them. If the list isn't available (a new branch or a force push), they run too.
2. **Mock gateway selftest** (Ubuntu): `npm ci && npm run selftest` in `mock-gateway/`.
3. **Swift build and checks** (macOS, `PINCER_KEYCHAIN=memory`):
   - Restores the cached `.build` folder
   - `swift build --build-tests`
   - `scripts/run-checks.sh`, which starts five mocks, waits until they all listen (it checks every 50 ms and fails with a mock's log if it exits or isn't up within 30 seconds), and then runs these **at the same time**:
     - `swift test --skip-build --parallel`
     - `PincerChecks`
     - `PincerChecks --demo-core` and `PincerChecks --demo-extras` (with `PINCER_DEMO_DELAY_SCALE=0.2`)
     - `PincerChecks --live-core` and `PincerChecks --live-extras` (with `PINCER_DEMO_DELAY_SCALE=0.2`), each against its own mock
     - `PincerChecks --live-no-usage` against a mock started with `MOCK_NO_USAGE=1`
     - `PincerChecks --live-no-reply-to` against a mock started with `MOCK_NO_REPLY_TO=1`
     - `PincerChecks --live-reconnect` (bootstrap races, overlapping reconnects and per-launch RPC counts) against its own mock

     Only the plain `PincerChecks` run does the Shortcuts & Siri offline checks; the others pass `--skip-intent-checks`. Because they share the CPU (CI runners have 3 cores), they all pass `--skip-perf-budgets`. After they finish, `PincerChecks --perf-smoke` runs alone and enforces the perf smoke budgets. Then the unit tests with wall-clock budgets run alone with `PINCER_STRICT_PERF=1`; in the parallel `swift test` lane they're only held to five times their budget. The script prints each run's log, then a summary with each run's time. If a run fails, CI uploads the logs.

`.github/workflows/docs.yml` builds the website (`npm ci && npm run build` in `website/`) on pull requests and pushes to `main` that change it.

CI passes `-Xswiftc -enable-incremental-file-hashing` to every `swift` command. Checkout gives every file a new modification time, so without it the restored build would recompile everything.

To reproduce CI locally, run `npm ci` in `mock-gateway/` and `swift build --build-tests`, then `scripts/run-checks.sh`. It starts its own mocks on ports 18801–18805 (set `CHECKS_PORT_BASE` to use others) and writes logs to a temporary folder (or `CHECKS_LOG_DIR`). Each check run keeps its drafts, transcript cache and saved gateways in its own scratch folders and defaults suites, so the demo and live runs can safely run at the same time.

## Environment variables

| Variable | Effect |
| --- | --- |
| `PINCER_KEYCHAIN=memory` | Keep identities and secrets in memory, so dev runs never touch your real Keychain. `PincerChecks` and `swift test` always do this. |
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
| `Sources/PincerChecks` | Self-checks: per-domain `*Checks.swift` files, and `Registry.swift` listing which run in each mode. |
| `Sources/PincerPush` | Web Push decryption (RFC 8291), per-gateway push keys and payload parsing, shared by the app and its notification service extension. |
| `push-relay/` | Zero-dependency Node relay from Gateway Web Push to APNs. See [Push notifications](../../guides/push-notifications/). |
| `Tests/PincerKitTests` | Unit tests for PincerKit (`swift test`). |
| `Tests/PincerUITests` | Unit tests and the streaming performance probe for the shared transcript UI (`swift test`). |
| `mock-gateway/` | Node mock of the Gateway protocol for offline development. |
| `website/` | This documentation site. |

## Known gaps

- iOS runs in the simulator (connect, sidebar, history) but hasn't been tried on a real device yet.
- Gateway Settings has been tested against the mock only.

## Parallel dev worktrees

Builds from different git worktrees would otherwise share profiles, Keychain items, drafts, outboxes and caches. Give each worktree a development namespace; production builds have none and keep their exact identifiers.

```sh
PINCER_DEV_NAMESPACE=feature-x swift run PincerMacDev       # own Keychain service, UserDefaults suite, Drafts/Outbox folders
xcodebuild -scheme Pincer-macOS PINCER_DEV_SUFFIX=.dev-feature-x   # bundle ids, App Group and Keychain group get the suffix
```

With the suffix, `chat.pincer.mac` becomes `chat.pincer.mac.dev-feature-x`, the Keychain service `chat.pincer.gateway.dev-feature-x`, and storage folders `Pincer-feature-x`. Use the same name for both variables. On iOS the suffixed App Group and bundle ids need provisioning, so set the suffix there only when you want an isolated install. The push relay rejects the suffixed iOS topic (`chat.pincer.ios.dev-x`) unless you add it to its `APNS_TOPICS`, and it needs the aps capability provisioned. Both builds register the same `pincer://` URL scheme and Handoff type, so links and Handoff may open the other build. `PINCER_CACHE_DIR`, `PINCER_DRAFTS_DIR` and `PINCER_OUTBOX_DIR` still override folders explicitly.
