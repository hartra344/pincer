import Foundation

/// A model that builds from a `JSONValue` with `init?(_:)` and decodes through it: the default
/// `init(from:)` reads a `JSONValue`, then fails with `decodingFailure` when `init?(_:)` returns nil.
public protocol JSONValueDecodable: Decodable {
    init?(_ json: JSONValue)
    /// The `debugDescription` of the `DecodingError` thrown when `init?(_:)` rejects the value.
    static var decodingFailure: String { get }
}

extension JSONValueDecodable {
    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let value = Self(json) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: Self.decodingFailure)
        }
        self = value
    }
}
