---
title: Building from source
description: Build Pincer for macOS and iOS, run the unit tests and self-checks, and find your way around the code.
---

## Requirements

- A current **Xcode** with Swift 6 and the macOS 15 / iOS 18 SDKs or later.
- The Xcode license accepted: `sudo xcodebuild -license accept`.

The SwiftUI macros only ship inside Xcode.app, so the Command Line Tools alone won't build the UI.

Background transcript fills establish a complete cache fingerprint baseline before saving so the search index can update only the changed tail. Visible chat opens keep their nonblocking cache path. The `TranscriptCachePrefillTests` repro and offline prefill indexing checks measure the number of built search documents and verify that old and appended messages remain searchable; token or schema mismatches still require a full recovery pass.

Composer and Quick Capture attachment thumbnails decode away from the main thread and downsample to their displayed pixel size, capped at 512 pixels. Decoded previews use a shared 16 MiB LRU; each visible thumbnail keeps only its own current small bitmap while mounted.

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

Text-growth transcript publishes are capped at 60 Hz; status and terminal updates remain immediate. A paired 25 KB streaming probe measured similar per-publish p95 main-actor elapsed time at 30 and 60 Hz (about 2.1 ms), while the summed publish time was about 87% higher at 60 Hz. The cap is fixed and does not track the display refresh rate; a 120 Hz display does not imply 120 Hz transcript updates.

Live automatic Read Aloud checks speakability on one shared background worker, with up to 32 pending items and 8 MiB of logical retained text and identifiers. Each item is limited to 64 text blocks and 256 KiB of joined text. Revisions of the same queued item keep their FIFO position; an active item retains one bounded latest revision, and an authoritative history refresh rechecks a completed candidate at its original position before the success barrier resolves. The byte budget counts logical UTF-8 bytes, not additional storage retained through Swift string copy-on-write. If admission exceeds a limit, automatic reading is suppressed for that run; transcript delivery and manual Listen remain available.

Composer and Quick Capture share one attachment-preparation FIFO: one item is active, with up to 32 pending descriptors and 32 MiB of pending in-memory data. Image codec work runs off-main; the UIKit fallback that turns a pasteboard `UIImage` into PNG data still runs before that queue. `AttachmentPreparationTests` checks the real ingest path and codec executor, while the demo check exercises queue budgets and a small PNG round trip.

Composer autosizing measures the full draft off the main thread, keeping one active measurement and one replaceable pending request. While a compatible measurement is pending, the native editor retains its previous height; width, font and line-cap changes request a new measurement. The hosted tests check the actual native editor height, including long drafts, wrapping and trailing newlines:

```sh
swift test --filter 'LatestMeasurementWorkerTests|ComposerSizingDiagnosticTests'
```

A Debug-only macOS probe exercises the same editor with a seeded Demo Gateway chat. It prints measurement counts, elapsed nanoseconds, main-thread counts and native height for 32 KiB and 128 KiB drafts. A successful run reports `main_count: 0` and matching native and measured heights. It uses a non-key window and verifies geometry, rather than foreground keyboard interaction:

```sh
PINCER_DEV_NAMESPACE=composer-sizing PINCER_KEYCHAIN=memory PINCER_DRAFTS_DIR=off \
  swift run PincerMacDev --composer-sizing-probe
```

CI also runs the transcript suites on an iPhone simulator, including live-versus-committed row layout, off-main inline math, and SVG rasterization. The hosted UIKit suite also resizes a native transcript from 390 to 600 points and back, checking measured row widths, row tops, collection content geometry, and the reader’s anchored row and screen position. Synthetic and seeded Demo transcripts verify that status-bar scroll-to-top is disabled and its delegate rejects the request without changing position, while manual browsing still moves the reader’s anchor. These native checks do not simulate a physical status-bar tap. To run those rendering suites locally:

```sh
scripts/ios-test-scheme.sh
xcodebuild test -scheme PincerUITests-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath .build/xcode-ios \
  -only-testing:PincerUITests/StreamingRenderingTests \
  -only-testing:PincerUITests/InlineMathOffMainTests \
  -only-testing:PincerUITests/SVGRasterizerTests
```

Use an available iPhone simulator name from `xcrun simctl list devices available`. SVG rendering can produce WebKit process logs in the simulator; the test assertions determine whether rasterization succeeded.

The iPad sidebar geometry probe hosts a 1,200-row transcript in `NavigationSplitView`, drives the public native `UISplitViewController` hide/show transition, and reports detail-width changes and row builds per display frame. It checks that the native column actually changes and that layouts stay bounded while the sidebar animates. This measures native geometry; it does not test the SwiftUI sidebar button binding. Run it on a regular-width iPad simulator (the default iPhone CI lane does not run this probe):

```sh
scripts/ios-test-scheme.sh
xcodebuild test -scheme PincerUITests-iOS \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath .build/xcode-ipad \
  -only-testing:PincerUITests/TranscriptSidebarSlideProbe
```

Use an available iPad simulator name from `xcrun simctl list devices available`.

The iOS `StreamingRenderingTests` suite also prints a UIKit streaming baseline for 2, 10, and 25 KB markdown replies. It sends prepared events through `ChatStore`, flushes every two simulated tokens, and updates an actual hosted collection view. CPU windows cover event handling and synchronous native publishing; fixture setup and the run-loop yield between publishes are excluded. It checks the growing body, visible cell, row geometry, and a separate committed-row off-main premeasure warmup. There is no timing cutoff yet.

On an iPhone 18 Pro / iOS 27 simulator in a Debug build, the baseline was:

| Reply | Mean token CPU | Max token CPU | Max publish CPU |
| --- | ---: | ---: | ---: |
| 2 KB | 1.289 ms | 4.498 ms | 8.490 ms |
| 10 KB | 1.485 ms | 3.463 ms | 6.623 ms |
| 25 KB | 2.020 ms | 4.128 ms | 7.629 ms |

These are simulated event/render costs, not physical-device timings or a measured network cadence. Run the `StreamingRenderingTests` command above to collect the table on another simulator.

While a reply streams, text-growth updates are coalesced to the configured frame interval. If the wall clock moves backward, negative elapsed time is treated as zero so a coalesced update waits no longer than one frame; normal bursts and already-due updates keep their existing timing. Status and terminal updates remain immediate. Finished paragraphs are laid out once and only the paragraph being written is measured again, so the cost of each update stays flat as the reply grows.

## Self-checks

While `scripts/run-checks.sh` waits for its parallel lanes, it prints a bounded progress snapshot about every 30 seconds. The snapshot names the pending lane, process, log filename, and last recognized unfinished unit-test identifier; it never prints raw log tails or test arguments. Started and finished counts cover only the bounded portion observed, with `skipped=1` when earlier output could not be retained. Final logs and exit status are unchanged. The progress reader stops before the solo performance lanes, which keep the CPU to themselves.

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

Debug checks also enforce a deterministic sidebar work budget: a section build derives each eligible row's parent candidates at most once. This covers all organization modes and the built-in demo without relying on wall-clock timing or a persistent section cache.

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
PINCER_DEV_NAMESPACE=feature-x scripts/bundle-mac.sh release  # embeds the namespace in build/Pincer.app
xcodebuild -scheme Pincer-macOS PINCER_DEV_SUFFIX=.dev-feature-x   # bundle ids, App Group and Keychain group get the suffix
```

The SwiftPM Mac bundler sanitizes the namespace to lowercase letters, digits, and dashes, capped at 24 characters. It writes the bundle ID suffix and `PincerDevSuffix` into Info.plist, so launching the bundle later keeps its isolated storage without needing the environment variable. Empty or unusable names keep the production identity. Run `python3 scripts/test_bundle_mac_namespace.py` to check the generated metadata with isolated build-tool fixtures.

Xcode builds validate `PINCER_DEV_SUFFIX` before compiling each app or extension. Leave it empty for production identity, or use `.dev-` followed by 1–24 lowercase letters and digits separated by single hyphens (for example, `.dev-feature-x`). Xcode suffixes must already be canonical; invalid values fail the build rather than being normalized. GitHub Actions checks the generated pre-build phases for all five targets. Run `python3 scripts/test_xcode_dev_suffix.py --direct` for validator cases, or `python3 scripts/test_xcode_dev_suffix.py --generated` to generate and exercise the phases locally (requires XcodeGen).

With the suffix, `chat.pincer.mac` becomes `chat.pincer.mac.dev-feature-x`, the Keychain service `chat.pincer.gateway.dev-feature-x`, and storage folders `Pincer-feature-x`. Use the same name for both variables. On iOS the suffixed App Group and bundle ids need provisioning, so set the suffix there only when you want an isolated install. The push relay rejects the suffixed iOS topic (`chat.pincer.ios.dev-x`) unless you add it to its `APNS_TOPICS`, and it needs the aps capability provisioned. Both builds register the same `pincer://` URL scheme and Handoff type, so links and Handoff may open the other build. `PINCER_CACHE_DIR`, `PINCER_DRAFTS_DIR` and `PINCER_OUTBOX_DIR` still override folders explicitly.

Cold transcript premeasurement prepares exact message sources on one shared background worker. Up to 64 waiting descriptors retain weak list owners and short native row IDs, with no queued message bodies. One active COW row snapshot and its exact joined text can cost the size of that message; editing can fork shared buffers. This transient memory is not covered by the 4 MiB retained source-memo budget. Finished text and geometry use the existing caches and revision checks. Width prewarm takes the same single lease before each wait, adopts one result before acquiring the next, and yields to queued work when busy. Denied lists each keep one weak, removable capacity observation and at most one queued retry callback. Their metadata fanout scales with the number of currently denied lists; it is not a globally fixed-size observer pool. Metadata warm shortcuts remain; a cold body already warmed by another row may be measured once again in the background. Existing visible layout and unsupported-content paths are unchanged.


Debug reconnect checks wait for the current connection's actual bootstrap and preference/reconciliation tasks to finish before comparing RPC counts. The reconnect history-count check also requires successfully persisted launch caches; a completed prefetch alone does not prove a cache write succeeded. Release checks retain the legacy readiness fallback.


Cache-reconciliation checks observe the actual directory inventory on the cache writer's background actor. They verify that an authoritative complete session list removes orphan manifests while current chats and retained outbox entries keep theirs, including owners created while inventory is in flight. Session-key hashing and live-owner bookkeeping remain separate main-actor work; these checks do not establish a physical interaction-latency improvement.
