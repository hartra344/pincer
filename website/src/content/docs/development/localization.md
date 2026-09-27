---
title: Localization
description: Where Pincer's strings live, how to write localizable UI code, and how to add a language.
---

Pincer is in English today. Moving the UI's strings into a String Catalog is ongoing, so some screens still have hard-coded English text. New and changed UI text should go through the catalog.

## Where strings live

User-facing strings for the shared UI are in a String Catalog:

```
Sources/PincerUI/Resources/Localizable.xcstrings
```

`Package.swift` sets `defaultLocalization: "en"` and bundles `Resources/` with the `PincerUI` target. The catalog is compiled into PincerUI's own SwiftPM resource bundle, **not** the app's main bundle.

## Writing localizable code

Because the strings are in the package bundle, always look them up with `bundle: .module`. A bare `Text("Send")` or `String(localized: "Send")` searches `Bundle.main`, finds nothing and quietly falls back to English.

```swift
// SwiftUI text
Text("Send", bundle: .module)
Text(l: "Send")                          // shorthand from Localization.swift

// Anywhere a String is needed: labels, help, accessibility, alerts
String(localized: "Copy message", bundle: .module)
L("Copy message")                        // shorthand from Localization.swift

.accessibilityLabel(L("Attach file"))
.help(L("Stop the current run"))
```

`L()` and `Text(l:)` are defined in `Sources/PincerUI/Localization.swift`.

Some tips:

- Interpolate values rather than joining strings, so translators can reorder them: `L("Show \(count) subagent runs")`.
- Don't build sentences from fragments like `"Show " + title`. Word order differs between languages.
- Names, titles, message text and anything else from the gateway are data. Don't localize them.
- `PincerKit` has no resource bundle. Its VoiceOver text builders (`AccessibilityText` in `Sources/PincerKit/AccessibilityLabels.swift`) compose English phrases from parts. When a language is added, pass the fixed phrases in from PincerUI's catalog.

## Adding or updating strings

1. Use the string in code with `bundle: .module` (or `L()` / `Text(l:)`).
2. Open the Xcode project (`xcodegen generate`, then `open Pincer.xcodeproj`) and build. Xcode adds new keys to `Localizable.xcstrings`.
3. Open the catalog and add a **comment** for any key whose meaning isn't obvious, like where it appears or what a placeholder holds.

## Adding a language

1. Open `Sources/PincerUI/Resources/Localizable.xcstrings` in Xcode.
2. Click **+** at the bottom of the language list and choose the language.
3. Translate each key. Use **Vary by Plural** for strings with counts.
4. Build and run with the new language. In Xcode, edit the scheme and set **Run → Options → App Language**, or change your system language.
5. Check that nothing is truncated or overlapping, especially in the sidebar, the composer and Settings.

Commit the updated `.xcstrings` file. It's JSON, so review the diff like any other change.
