import Foundation

/// Text-only opening for an unrendered rotor row. Rendered accessibility labels remain complete.
package enum ColdRotorTextOpening {
    package static let bodyByteLimit = 400
    package static let authorByteLimit = 128
    package static let blockLimit = 64
    package struct Capture: Sendable {
        package var text: String
        package var inspectedBytes: Int
        package var visitedBlocks: Int
    }
    package static func capture(blocks: [ContentBlock]) -> Capture {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(bodyByteLimit)
        var visited = 0
        var seenText = false
        for block in blocks.prefix(blockLimit) {
            guard bytes.count < bodyByteLimit else { break }
            visited += 1
            guard case let .text(text) = block else { continue }
            if seenText { bytes.append(contentsOf: [10, 10].prefix(bodyByteLimit - bytes.count)) }
            seenText = true
            guard text.isContiguousUTF8 else { break }
            guard text.utf8.withContiguousStorageIfAvailable({ buffer -> Bool in
                bytes.append(contentsOf: buffer.prefix(bodyByteLimit - bytes.count))
                return true
            }) == true else { break }
        }
        return Capture(text: decode(bytes), inspectedBytes: bytes.count, visitedBlocks: visited)
    }
    package static func capture(text: String) -> Capture { capture(blocks: [.text(text)]) }
    package static func author(_ text: String) -> Capture {
        guard text.isContiguousUTF8,
              let bytes = text.utf8.withContiguousStorageIfAvailable({ Array($0.prefix(authorByteLimit)) }) else {
            return Capture(text: "", inspectedBytes: 0, visitedBlocks: 0)
        }
        return Capture(text: decode(bytes), inspectedBytes: bytes.count, visitedBlocks: 0)
    }
    private static func decode(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        // Original Swift strings are valid UTF8. Only the bounded cut can be incomplete.
        var end = bytes.count
        var start = end - 1
        while start > 0 && bytes[start] & 0xC0 == 0x80 { start -= 1 }
        let leading = bytes[start]
        let expected = leading < 0x80 ? 1 : leading < 0xE0 ? 2 : leading < 0xF0 ? 3 : 4
        if end - start < expected { end = start }
        return String(decoding: bytes.prefix(end), as: UTF8.self)
    }
}
