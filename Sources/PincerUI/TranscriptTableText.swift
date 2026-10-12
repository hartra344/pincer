import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A table's selectable text: rendered cell strings joined by "\t" between cells and "\n" between rows,
/// so any range of it is already the plain text to copy. Offsets are UTF-16 (NSString).
///
/// Nothing is built until first use. Per-cell TextKit layouts are created lazily for the cells that are
/// hit-tested or highlighted, and live as long as this object (one per table value).
@MainActor
final class TranscriptTableText {
    @MainActor private final class CellLayout {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer

        init(_ text: NSAttributedString, width: CGFloat) {
            let (storage, container) = TranscriptTextKit.stack(wraps: true)
            container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            storage.setAttributedString(text)
            self.storage = storage
            self.container = container
            self.manager = container.layoutManager!
            self.manager.ensureLayout(for: container)
        }
    }

    private let table: TranscriptPart.Table
    private let columns: Int
    private var starts: [Int] = []
    private var layouts: [Int: CellLayout] = [:]
    private var columnOrigins: [CGFloat] = []
    private var rowOrigins: [CGFloat] = []
    let string: NSString

    var length: Int { self.string.length }

    init(table: TranscriptPart.Table) {
        self.table = table
        let columns = table.columnWidths.count
        self.columns = columns
        var result = ""
        var starts: [Int] = []
        var offset = 0
        for (rowIndex, row) in table.cells.enumerated() {
            if rowIndex > 0 { result += "\n"; offset += 1 }
            for column in 0..<columns {
                if column > 0 { result += "\t"; offset += 1 }
                starts.append(offset)
                if column < row.count {
                    let text = row[column].string
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                        .replacingOccurrences(of: "\u{2028}", with: " ")
                        .replacingOccurrences(of: "\u{2029}", with: " ")
                    result += text
                    offset += (text as NSString).length
                }
            }
        }
        self.string = result as NSString
        self.starts = starts
        var x: CGFloat = 0
        for width in table.columnWidths { self.columnOrigins.append(x); x += width }
        var y: CGFloat = 0
        for height in table.rowHeights { self.rowOrigins.append(y); y += height }
    }

    private var rows: Int { self.columns == 0 ? 0 : self.table.cells.count }

    private func cellLength(row: Int, column: Int) -> Int {
        let index = row * self.columns + column
        let end: Int
        if column + 1 < self.columns {
            end = self.starts[index + 1] - 1
        } else if row + 1 < self.rows {
            end = self.starts[index + 1] - 1
        } else {
            end = self.length
        }
        return end - self.starts[index]
    }

    func range(row: Int, column: Int) -> NSRange {
        guard row >= 0, row < self.rows, column >= 0, column < self.columns else { return NSRange(location: 0, length: 0) }
        return NSRange(location: self.starts[row * self.columns + column], length: self.cellLength(row: row, column: column))
    }

    func cell(containing offset: Int) -> (row: Int, column: Int) {
        guard !self.starts.isEmpty else { return (0, 0) }
        let offset = min(max(offset, 0), self.length)
        // Last cell whose start is <= offset.
        var low = 0, high = self.starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if self.starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return (low / self.columns, low % self.columns)
    }

    func text(in range: NSRange) -> String {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: self.length))
        return self.string.substring(with: clamped)
    }

    func textRect(row: Int, column: Int) -> CGRect {
        guard row >= 0, row < self.rowOrigins.count, column >= 0, column < self.columnOrigins.count else { return .zero }
        let width = self.table.columnWidths[column], height = self.table.rowHeights[row]
        return CGRect(x: self.columnOrigins[column] + 10, y: self.rowOrigins[row] + 5,
                      width: max(width - 20, 1), height: max(height - 10, 1))
    }

    private func layout(row: Int, column: Int) -> CellLayout? {
        let key = row * self.columns + column
        if let cached = self.layouts[key] { return cached }
        guard row < self.table.cells.count, column < self.table.cells[row].count else { return nil }
        let text = self.table.cells[row][column]
        guard text.length > 0 else { return nil }
        let layout = CellLayout(text, width: self.textRect(row: row, column: column).width)
        self.layouts[key] = layout
        return layout
    }

    func offset(at point: CGPoint) -> Int {
        guard !self.starts.isEmpty else { return 0 }
        let row = Self.index(of: point.y, in: self.rowOrigins)
        let column = Self.index(of: point.x, in: self.columnOrigins)
        let range = self.range(row: row, column: column)
        guard range.length > 0, let layout = self.layout(row: row, column: column) else { return range.location }
        let rect = self.textRect(row: row, column: column)
        let local = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
        var fraction: CGFloat = 0
        let character = layout.manager.characterIndex(for: local, in: layout.container,
                                                      fractionOfDistanceBetweenInsertionPoints: &fraction)
        let index = min(character + (fraction > 0.5 ? 1 : 0), range.length)
        return range.location + max(index, 0)
    }

    private static func index(of value: CGFloat, in origins: [CGFloat]) -> Int {
        var low = 0, high = origins.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if origins[mid] <= value { low = mid } else { high = mid - 1 }
        }
        return max(low, 0)
    }

    func selectionRects(for range: NSRange) -> [CGRect] {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: self.length))
        guard range.length > 0 else { return [] }
        let first = self.cell(containing: range.location), last = self.cell(containing: range.location + range.length)
        var rects: [CGRect] = []
        var row = first.row, column = first.column
        while row < last.row || (row == last.row && column <= last.column) {
            let cellRange = self.range(row: row, column: column)
            let overlap = NSIntersectionRange(range, cellRange)
            if overlap.length > 0, let layout = self.layout(row: row, column: column) {
                let origin = self.textRect(row: row, column: column).origin
                let local = NSRange(location: overlap.location - cellRange.location, length: overlap.length)
                let glyphs = layout.manager.glyphRange(forCharacterRange: local, actualCharacterRange: nil)
                layout.manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                       in: layout.container) { rect, _ in
                    rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
            column += 1
            if column >= self.columns { column = 0; row += 1 }
        }
        return rects
    }

    func caretRect(at offset: Int) -> CGRect {
        guard !self.starts.isEmpty else { return .zero }
        let offset = min(max(offset, 0), self.length)
        let (row, column) = self.cell(containing: offset)
        let cellRange = self.range(row: row, column: column)
        let origin = self.textRect(row: row, column: column).origin
        let local = min(max(offset - cellRange.location, 0), cellRange.length)
        guard cellRange.length > 0, let layout = self.layout(row: row, column: column) else {
            return CGRect(x: origin.x, y: origin.y, width: 1.5, height: TranscriptStyle.lineHeight(TranscriptStyle.shared.body))
        }
        let glyph = layout.manager.glyphIndexForCharacter(at: min(local, cellRange.length - 1))
        let line = layout.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var x = line.minX + layout.manager.location(forGlyphAt: glyph).x
        if local == cellRange.length {
            x = line.minX + layout.manager.location(forGlyphAt: glyph).x
                + layout.manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: layout.container).width
        }
        return CGRect(x: origin.x + x, y: origin.y + line.minY, width: 1.5, height: line.height)
    }

    func wordRange(at offset: Int) -> NSRange {
        guard !self.starts.isEmpty else { return NSRange(location: 0, length: 0) }
        let offset = min(max(offset, 0), self.length)
        let (row, column) = self.cell(containing: offset)
        let cell = self.range(row: row, column: column)
        guard cell.length > 0 else { return cell }
        var found: NSRange?
        var previous: NSRange?
        self.string.enumerateSubstrings(in: cell, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if offset >= range.location, offset < range.location + range.length {
                found = range
                stop.pointee = true
            } else if range.location + range.length <= offset {
                previous = range
            }
        }
        if let found { return found }
        if offset == cell.location + cell.length, let previous, previous.location + previous.length == offset { return previous }
        let at = min(offset, cell.location + cell.length - 1)
        return self.string.rangeOfComposedCharacterSequence(at: at)
    }

    func rowRange(at offset: Int) -> NSRange {
        guard !self.starts.isEmpty else { return NSRange(location: 0, length: 0) }
        let row = self.cell(containing: offset).row
        let first = self.range(row: row, column: 0), last = self.range(row: row, column: self.columns - 1)
        return NSRange(location: first.location, length: last.location + last.length - first.location)
    }
}
