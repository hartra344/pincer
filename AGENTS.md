# AGENTS.md

Guidance for coding agents (Copilot, Claude, Codex, …) working in this repo. Read it before you change anything. [CONTRIBUTING.md](CONTRIBUTING.md) says where new checks, mock handlers, demo data and docs go; this file doesn't repeat it.

## What Pincer is

Pincer is a native macOS and iOS SwiftUI client for the [OpenClaw](https://github.com/openclaw/openclaw) Gateway. It is a **pure operator client**: it connects over the Gateway WebSocket protocol in the `operator` role and **never** registers as a node, bundles or launches a Gateway, or exposes camera, screen, shell or `system.run` capabilities.

The upstream source of truth is [openclaw/openclaw](https://github.com/openclaw/openclaw). Verify every gateway method, param and event shape there before using it, in the app, the demo gateway and the mock gateway alike. **Never invent methods or fields.**

## Performance first (standing rule)

> **Every user interaction must feel instant.** Switching chats, opening menus, typing, scrolling and toggling panels must never hitch.

- **Nothing heavy on the main thread.** Parsing, text measuring, layout precomputation, disk I/O, JSON encoding/decoding, image and audio decoding, search and diffing all run off-main. The main thread only applies finished results.
- **Never gate a UI change on the network.** Show what's already in memory or on disk at once, then refresh in the background.
- **Cache aggressively, but bounded.** Use in-memory caches with an explicit budget (LRU eviction). Peak memory is about 400 MB today; staying well under ~1 GB is fine, gigabytes is not.
- **Show your cost.** A PR that touches an interaction path states its main-thread cost in the description, and adds or extends a perf probe or budget when practical. Existing ones to build on:
  - Transcript probes in `Tests/PincerUITests` (`StreamingProbe.swift`, `TranscriptPrefetchProbe.swift`, `PanelSlideProbe.swift`) and budgets via `PerfBudget` in `Tests/PincerKitTests/Support.swift`.
  - `Sources/PincerChecks/PerfChecks.swift` and `InvalidationPerfChecks.swift` (`PincerChecks --perf-smoke`), and `MemoryBoundsChecks.swift` / `MemoryProbe.swift`.
  - The solo `perf-smoke` and `perf-tests` lanes at the end of `scripts/run-checks.sh`, which enforce the wall-clock budgets with the CPU to themselves.

## Layout

| Path | What's there |
| --- | --- |
| `Sources/PincerKit` | Protocol client and observable stores, no UI: `GatewayConnection`, `GatewayStore(+…)`, `ChatStore(+…)`, `TranscriptCache`, `DemoGateway(+<Domain>)`, `Outbox`, `MessageIndex`, `Localization.swift`. |
| `Sources/PincerUI` | Shared SwiftUI for both platforms: `RootView.swift` (`PincerScene`), `SettingsPages.swift` (`GatewaySettingsForm`), `GatewaySettingsWindow.swift` and the Gateway Settings pages (`*Page.swift`), `Composer.swift`, the transcript list (`TranscriptListController.swift`, `TranscriptList+UIKit.swift`, `TranscriptList+AppKit.swift`, `TranscriptRow*`), the sidebar (`SidebarList+UIKit/AppKit.swift`), `Resources/Localizable.xcstrings`. |
| `Sources/PincerPush` | Web Push decryption, shared with the iOS Notification Service Extension. |
| `Sources/PincerChecks` | Self-checks run without XCTest (`swift run PincerChecks`); suites registered in `Registry.swift`. |
| `Sources/PincerMacDev` | SwiftPM entry point for the macOS app (also `--toolbar-stability-check`). |
| `Apps/iOS`, `Apps/macOS` | App targets (plus `Apps/Shared`, `Intents`, `ShareExtension`, `iOSNotificationService`), generated into `Pincer.xcodeproj` by XcodeGen from `project.yml`. |
| `Tests/PincerKitTests` | Pure-logic unit tests: no sockets, Keychain or shared defaults. |
| `Tests/PincerUITests` | UI-layer tests and perf probes (transcript rendering, streaming). |
| `mock-gateway/` | Node mock of the Gateway (`server.mjs`, one `<domain>.mjs` per area, `selftest/`). Port from the `PORT` env var (default 18789). |
| `website/` | Astro Starlight docs site. Pages in `website/src/content/docs`, sidebar in `website/astro.config.mjs`. |
| `push-relay/` | The optional iOS push relay. |

## Checks

CI (`.github/workflows/tests.yml`) runs all of these; run the relevant ones locally before pushing:

```sh
cd mock-gateway && npm ci && npm run selftest       # mock gateway selftest
swift build                                         # every target
swift test                                          # PincerKitTests + PincerUITests
swift run PincerChecks                              # offline suite
swift run PincerChecks --demo                       # against the built-in demo gateway
cd mock-gateway && PORT=18930 node server.mjs       # a FRESH mock, in another terminal
swift run PincerChecks --live ws://127.0.0.1:18930 dev-token
xcodegen generate                                   # then the app builds:
xcodebuild build -project Pincer.xcodeproj -scheme Pincer-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Pincer.xcodeproj -scheme Pincer-macOS CODE_SIGNING_ALLOWED=NO
cd website && npm ci && npm run build               # docs (Node >= 22.12)
```

- `scripts/run-checks.sh` (after `swift build --build-tests` and `npm ci` in `mock-gateway`) runs the unit tests and every `PincerChecks` mode side by side, each live mode against its own fresh mock, then the perf lanes solo. Mode names and env vars are in CONTRIBUTING.md and [Building](website/src/content/docs/development/building.md).
- Live modes change the mock's state: each needs a **fresh** mock.
- CI also runs the iOS transcript suites on a simulator (`scripts/ios-test-scheme.sh`, then `xcodebuild test -scheme PincerUITests-iOS`) and `PincerMacDev --toolbar-stability-check`.
- Docs-only changes (`website/`, top-level Markdown) skip the Swift jobs; `docs.yml` builds the website instead.
- **The machine is shared.** Run targeted tests (`swift test --filter …`, a single `PincerChecks` mode), not the whole world on every edit. No stress loops, no repeated full runs. Give parallel worktrees their own `PINCER_DEV_NAMESPACE` and set `PINCER_KEYCHAIN=memory` for checks.

## Testing rules

- Every change gets unit tests **and** PincerChecks coverage.
- Visible behaviour also gets demo and/or mock-gateway coverage (a `--demo-*` or `--live-*` check).
- A bug fix commits a failing repro (test or check) alongside the fix.

## Docs rules

- Feature behaviour is documented **only** in the website docs (`website/src/content/docs`, new pages get a sidebar entry in `website/astro.config.mjs`). Don't add feature bullets to `README.md`.
- Showcase visible features in the built-in demo (`DemoGateway`, **Try the Demo**) with realistic seeded data (`DemoGateway+Showcase.swift`).

## Localization

Route user-facing strings through `L()` (`Sources/PincerUI/Localization.swift`, `Sources/PincerKit/Localization.swift`) or `Text("key", bundle: .module)`, backed by `Sources/PincerUI/Resources/Localizable.xcstrings`. After changing UI strings, run `scripts/sync-strings.sh`. Localization is the **lowest priority**: never let it block or slow down a change.

## Issues and backlog

- Keep the backlog small: **at most 3 follow-up issues per PR**. Fold nits into one checklist issue. Search existing issues before filing.
- Every issue is a sub-issue of a "Track" parent issue. Find the Tracks with `gh issue list -R hartra344/pincer --search "Track:"`.
- #59 collects checks that need a real device; #60 is the roadmap.

## Git and PRs

- Merge `origin/main` into your branch before opening or updating a PR.
- Put `Closes #N` in the PR body for each issue it resolves.
- PRs are squash-merged. Never merge with failing or pending checks.
- End every commit message with the trailer:

  ```
  Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>
  ```
