---
title: Linting
description: The dead-code and duplication gates that run on every pull request, and how to run them locally.
---

Pincer has two lint gates. Both fail only on something **new**: each has a checked-in baseline in `scripts/lint/`, so existing findings don't block you, but a pull request can't add more.

| Gate | Finds | Covers | Baseline |
| --- | --- | --- | --- |
| Periphery | Unused Swift declarations and imports | `Sources/`, `Tests/` | `scripts/lint/periphery-baseline.json` |
| jscpd | Copy-pasted blocks (at least 70 tokens and 8 lines) | Swift and `.mjs` in `Sources/`, `Apps/`, `mock-gateway/`, `push-relay/` | `scripts/lint/jscpd-baseline.json` |
| knip | Unused files, exports and dependencies | `mock-gateway/`, `push-relay/` | none; it must be clean |

## Running them locally

```sh
scripts/lint.sh                      # every gate
scripts/lint.sh js                   # jscpd and knip only (about 15 seconds)
scripts/lint.sh periphery            # Periphery only
scripts/lint.sh periphery --skip-build   # reuse the index store from the last build
```

- The JS gates need Node 20.19 or newer and install their tools into `scripts/lint/node_modules` with `npm ci` on first use.
- The Periphery gate builds with `swift build --build-tests --enable-index-store` (incremental on top of your normal `.build`), then scans the index store, which takes about 10 seconds. It downloads the pinned Periphery release once into `~/.cache/pincer-lint` and checks its SHA-256. Set `PERIPHERY_BIN` to use your own binary, or `PERIPHERY_CACHE` to put it elsewhere. Any extra flags, such as `--scratch-path`, go to `swift build`.

## Fixing a failure

**Periphery** prints each new finding as `file:line: description`, and CI annotates the line.

- Delete the unused declaration.
- If it is used, but only from somewhere Periphery can't see, keep it and say why. Periphery scans the macOS debug SwiftPM build, so it can't see `Apps/` (the app targets, extensions and intents) or code behind `#if os(iOS)`, `canImport(UIKit)` or the `#else` of `#if DEBUG`. Add a comment on the declaration:

  ```swift
  // periphery:ignore - called from Apps/iOS/IntentService.swift
  ```

  or add it to `scripts/lint/periphery-baseline.json` with a `reason`. Matching ignores line numbers, so edits elsewhere in a file don't break it; an entry with `count` covers that many same-named declarations in the file.
- Unused function parameters aren't reported, and neither is an unused import in a file that has an iOS-only region, or a property read only through its `$` projection (a `@State` passed on as a binding), which Periphery 3.8 misses.

Configuration is in `.periphery.yml`. Public declarations count (most of PincerKit is `public`). `Codable` properties, `@objc` members, SwiftUI previews and properties that are only ever assigned are kept: assign-only reports were nearly all `Equatable` task keys, retained tasks and observers, and decoded fields.

**jscpd** fails when the number of clones or the duplicated percentage goes above the baseline. It lists the clones in files you changed. Extract the shared code into a helper instead of copying it.

**knip** fails on any unused file, export or dependency in `mock-gateway/` or `push-relay/`. Delete it, or stop exporting it. Its configs are `scripts/lint/knip.mock-gateway.jsonc` and `scripts/lint/knip.push-relay.jsonc`.

## Updating a baseline

When a pull request removes duplication or dead code, lower the baseline so it stays removed:

```sh
scripts/lint.sh --update-baselines
```

For Periphery, this writes every current finding to the baseline, and new entries get a `TODO` reason. The gate fails until every `TODO` is replaced with a real reason, so only keep entries you can justify; delete the rest of the code instead. Stale entries (whose code is gone) are listed so you can remove them.

## SwiftLint

There's no SwiftLint gate. Formatting and style are kept by review, and the issues SwiftLint would catch that matter here (dead code, copy-paste) are covered by the gates above. Adding it would mean a large one-time churn across every file.

## In CI

`tests.yml` runs the gates in two jobs, in parallel with the Swift shards, and the required **Swift build and checks** check fails if either fails. Both are skipped for docs-only changes.

- **Lint (jscpd, knip)** (Ubuntu): `scripts/lint/js.sh`, with the npm cache keyed on `scripts/lint/package-lock.json`.
- **Lint (Periphery)** (macOS): restores its own `.build` cache (the index store changes the build, so it can't share the unit shard's), builds with the index store, and runs `scripts/lint/periphery.sh --skip-build`. The Periphery binary is cached by version.
