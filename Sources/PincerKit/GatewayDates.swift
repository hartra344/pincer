import Foundation

/// Shared Gateway date helpers. The formatters are cached: `ISO8601DateFormatter` is thread-safe
/// and these are configured once and never mutated.
public enum GatewayDates {
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    /// ISO-8601 with fractional seconds, else plain internet date-time.
    public static func iso(_ text: String) -> Date? {
        self.isoFractional.date(from: text) ?? self.isoPlain.date(from: text)
    }

    /// ISO-8601 internet date-time with fractional seconds.
    public static func isoString(_ date: Date) -> String {
        self.isoFractional.string(from: date)
    }

    public static func date(epochMillis ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }
}

extension JSONValue {
    /// Epoch milliseconds (a number or numeric string) as a `Date`. `positiveOnly` rejects zero and
    /// negatives; `requireFinite` rejects infinities and NaN.
    public func epochMillisDate(positiveOnly: Bool = false, requireFinite: Bool = false) -> Date? {
        guard let ms = self.double else { return nil }
        if requireFinite, !ms.isFinite { return nil }
        if positiveOnly, !(ms > 0) { return nil }
        return GatewayDates.date(epochMillis: ms)
    }
}

/// The "advertised (or the list is unknown) and not rejected" rule shared by the models.
public enum GatewayMethodSupport {
    public static func supports(_ method: String, advertised: Set<String>?, rejected: Set<String> = []) -> Bool {
        if rejected.contains(method) { return false }
        guard let advertised, !advertised.isEmpty else { return true }
        return advertised.contains(method)
    }
}
