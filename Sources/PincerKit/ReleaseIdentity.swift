import Foundation

/// Reads the shipping bundle IDs from `project.yml` and `scripts/testflight.sh`, so checks can
/// confirm the iOS app ships under the Mac app's App Store record (universal purchase, #1065).
package enum ReleaseIdentity {
    /// `PRODUCT_BUNDLE_IDENTIFIER` per XcodeGen target, with `$(PINCER_DEV_SUFFIX)` removed.
    package static func bundleIdentifiers(projectYAML: String) -> [String: String] {
        self.targetSettings(projectYAML: projectYAML, key: "PRODUCT_BUNDLE_IDENTIFIER")
    }

    /// The first value of a build setting per XcodeGen target, with `$(PINCER_DEV_SUFFIX)` removed.
    package static func targetSettings(projectYAML: String, key: String) -> [String: String] {
        var result: [String: String] = [:]
        var inTargets = false
        var target: String?
        for line in projectYAML.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.hasPrefix(" "), !line.isEmpty, !line.hasPrefix("#") {
                inTargets = line.hasPrefix("targets:")
                target = nil
                continue
            }
            guard inTargets else { continue }
            if line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":"), !line.contains("#") {
                target = String(line.dropFirst(2).dropLast())
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "\(key):"
            if let target, trimmed.hasPrefix(prefix), result[target] == nil {
                result[target] = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "$(PINCER_DEV_SUFFIX)", with: "")
            }
        }
        return result
    }

    /// `BUNDLE_ID` per platform in `scripts/testflight.sh`, plus every bundle ID it maps to a profile.
    package static func testFlightBundleIdentifiers(script: String) -> (apps: [String: String], extraProfileKeys: [String]) {
        let apps = self.testFlightVariable("BUNDLE_ID", script: script)
        var keys: [String] = []
        var rest = Substring(script)
        while let open = rest.range(of: "EXTRA_PROFILES=\"<key>") {
            let tail = rest[open.upperBound...]
            guard let close = tail.range(of: "</key>") else { break }
            keys.append(String(tail[..<close.lowerBound]))
            rest = tail[close.upperBound...]
        }
        return (apps, keys)
    }

    /// A `NAME=value` assignment per platform case in `scripts/testflight.sh`.
    package static func testFlightVariable(_ name: String, script: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in script.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let platformEnd = trimmed.firstIndex(of: ")"),
                  let range = trimmed.range(of: " \(name)=") ?? trimmed.range(of: ";\(name)=") else { continue }
            let value = trimmed[range.upperBound...].prefix { $0 != ";" && $0 != " " }
            values[String(trimmed[..<platformEnd])] = String(value)
        }
        return values
    }
}
