import Foundation
import os

/// Where PincerKit looks up its user-facing sentences.
///
/// PincerKit has no resource bundle of its own: its error messages, accessibility phrases and sender
/// names are keys in PincerUI's String Catalog (`Sources/PincerUI/Resources/Localizable.xcstrings`),
/// so translators work in one file. PincerUI registers its bundle at launch. Until then (unit tests,
/// `PincerChecks`, the share extension) lookups fall back to the main bundle, which has no catalog,
/// so they return the English key with its values filled in.
public enum PincerStrings {
    private static let storage = OSAllocatedUnfairLock<Bundle?>(initialState: nil)

    /// The bundle holding the catalog, set by PincerUI.
    public static var bundle: Bundle? {
        get { self.storage.withLock { $0 } }
        set { self.storage.withLock { $0 = newValue } }
    }
}

/// A localized string from PincerUI's catalog (see `PincerStrings`). Keys are the English text.
func L(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
    String(localized: key, bundle: PincerStrings.bundle ?? .main, comment: comment)
}
