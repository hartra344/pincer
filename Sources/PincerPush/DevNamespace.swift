import Foundation

/// Optional development namespace that keeps parallel builds (git worktrees) from sharing
/// persisted state: Keychain service and access group, UserDefaults suite, and the
/// Application Support / Caches folders. Production has no namespace and every name is unchanged.
///
/// Set `PINCER_DEV_NAMESPACE=<name>` in the environment for SwiftPM runs (`swift run PincerMacDev`,
/// PincerChecks). Xcode builds pass `PINCER_DEV_SUFFIX=.dev-<name>`, which project.yml applies to the
/// bundle ids, App Group and Keychain group and exposes through the `PincerDevSuffix` Info.plist key.
public enum DevNamespace {
    public static let environmentKey = "PINCER_DEV_NAMESPACE"
    public static let infoKey = "PincerDevSuffix"
    public static let maxLength = 24
    public static let suffixPrefix = ".dev-"

    /// The active namespace: the environment variable first, then the Info.plist suffix.
    public static let current: String? = resolve(
        environment: ProcessInfo.processInfo.environment[environmentKey],
        infoValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)

    public static func resolve(environment: String?, infoValue: String?) -> String? {
        if let fromEnvironment = sanitize(environment) { return fromEnvironment }
        guard var raw = infoValue, !raw.contains("$(") else { return nil }
        if raw.hasPrefix(suffixPrefix) { raw.removeFirst(suffixPrefix.count) }
        return sanitize(raw)
    }

    /// Lowercases and reduces to `[a-z0-9-]` (other runs become one `-`), trims dashes and
    /// bounds the length. Nil when nothing usable is left.
    public static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var out = ""
        for scalar in raw.lowercased().unicodeScalars {
            let ok = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if ok { out.unicodeScalars.append(scalar) } else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = String(out.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `base` in production, `base.dev-<ns>` when namespaced (dot-separated identifiers).
    public static func identifier(_ base: String, namespace: String? = DevNamespace.current) -> String {
        namespace.map { "\(base).dev-\($0)" } ?? base
    }

    /// `name` in production, `name-<ns>` when namespaced (storage folder names).
    public static func folderName(_ name: String, namespace: String? = DevNamespace.current) -> String {
        namespace.map { "\(name)-\($0)" } ?? name
    }
}
