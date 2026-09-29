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

// Anywhere a String is needed: labels, help, accessibility, alerts
String(localized: "Copy message", bundle: .module)
L("Copy message")                        // shorthand from Localization.swift

.accessibilityLabel(L("Attach file"))
.help(L("Stop the current run"))
```

`L()` is defined in `Sources/PincerUI/Localization.swift`.

Some tips:

- Interpolate values rather than joining strings, so translators can reorder them: `L("Show \(count) subagent runs")`.
- Don't build sentences from fragments like `"Show " + title`. Word order differs between languages.
- Names, titles, message text and anything else from the Gateway are data. Don't localize them.
- `PincerKit` has no resource bundle. Its VoiceOver text builders (`AccessibilityText` in `Sources/PincerKit/AccessibilityLabels.swift`) compose English phrases from parts. When a language is added, pass the fixed phrases in from PincerUI's catalog.

## Adding or updating strings

1. Use the string in code with `bundle: .module`, or `L()`.
2. Regenerate the catalog:

   ```sh
   scripts/sync-strings.sh              # builds PincerUI for macOS and the iOS Simulator, then syncs
   scripts/sync-strings.sh --skip-build # reuses the last run's extraction output in build/strings
   ```

   The script builds the `PincerUI` scheme with the compiler's string extraction turned on, then runs `xcstringstool sync` over every PincerUI file that uses `bundle: .module` or `L("…")`. Each key's English value is the key itself. Keys with no letters, such as `"%@ %@"`, are left out because there's nothing to translate. Existing translations and comments are kept, and keys that are no longer used in code are removed. It needs Xcode, and the full run takes a few minutes.
3. Commit `Localizable.xcstrings` along with your code change.

Don't add keys by hand or by building the app in Xcode. The catalog's entries have no extraction state, so let the script keep it in step with the code.

## Adding a language

1. Open `Sources/PincerUI/Resources/Localizable.xcstrings` in Xcode.
2. Click **+** at the bottom of the language list and choose the language.
3. Translate each key. Use **Vary by Plural** for strings with counts, and add a **comment** to any key whose meaning isn't obvious, like where it appears or what a placeholder holds.
4. Build and run with the new language. In Xcode, edit the scheme and set **Run → Options → App Language**, or change your system language.
5. Check that nothing is truncated or overlapping, especially in the sidebar, the composer and Settings.

Commit the updated `.xcstrings` file. It's JSON, so review the diff like any other change.
