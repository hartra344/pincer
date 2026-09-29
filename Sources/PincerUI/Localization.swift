import Foundation
import SwiftUI

// PincerUI's strings live in its SwiftPM bundle (`Resources/Localizable.xcstrings`), not the app's
// main bundle, so a bare `Text("literal")` would miss them. Use `Text("key", bundle: .module)` for
// views and `L("key")` wherever a `String` is needed (labels, help, accessibility, alerts).

/// A localized string from PincerUI's catalog.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
