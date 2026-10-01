import Foundation
import PincerKit

/// A count-bounded least-recently-used cache with O(1) get and set. Overflow evicts only the
/// oldest entry, so a burst of new keys never throws away the whole warm set.
struct LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var newer: Node?
        unowned(unsafe) var older: Node?
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    let capacity: Int
    private var nodes: [Key: Node] = [:]
    private var newest: Node?
    private unowned(unsafe) var oldest: Node?
    private(set) var evictionGeneration: UInt64 = 0

    init(capacity: Int) { self.capacity = max(capacity, 1) }

    var count: Int { self.nodes.count }

    mutating func value(for key: Key) -> Value? {
        guard let node = self.nodes[key] else { return nil }
        self.touch(node)
        return node.value
    }

    mutating func set(_ value: Value, for key: Key) {
        if let node = self.nodes[key] {
            node.value = value
            self.touch(node)
            return
        }
        let node = Node(key: key, value: value)
        self.nodes[key] = node
        self.pushNewest(node)
        if self.nodes.count > self.capacity, let last = self.oldest {
            self.unlink(last)
            self.nodes[last.key] = nil
            self.evictionGeneration &+= 1
        }
    }

    mutating func removeAll() {
        // Break the strong `newer` chain iteratively so a long list can't overflow the stack on release.
        var node = self.newest
        while let current = node {
            node = current.newer
            current.newer = nil
        }
        self.nodes.removeAll()
        self.newest = nil
        self.oldest = nil
        self.evictionGeneration &+= 1
    }

    private mutating func touch(_ node: Node) {
        guard self.newest !== node else { return }
        self.unlink(node)
        self.pushNewest(node)
    }

    private mutating func pushNewest(_ node: Node) {
        node.newer = nil
        node.older = self.newest
        self.newest?.newer = node
        self.newest = node
        if self.oldest == nil { self.oldest = node }
    }

    private mutating func unlink(_ node: Node) {
        if self.newest === node { self.newest = node.older }
        if self.oldest === node { self.oldest = node.newer }
        node.older?.newer = node.newer
        node.newer?.older = node.older
        node.newer = nil
        node.older = nil
    }
}

/// Parsing markdown on every render made long transcripts stutter while scrolling.
/// Live (streaming) rows never come through here: their text changes every flush, so caching it
/// would only evict the committed rows' entries.
@MainActor
enum MarkdownCache {
    static let blockCapacity = 1500
    static let inlineCapacity = 6000

    private static var blockCache = LRUCache<String, [MarkdownBlock]>(capacity: MarkdownCache.blockCapacity)
    private static var inlineCache = LRUCache<String, AttributedString>(capacity: MarkdownCache.inlineCapacity)

    /// Entry counts, for tests.
    static var counts: (blocks: Int, inlines: Int) { (self.blockCache.count, self.inlineCache.count) }

    static func blocks(_ source: String) -> [MarkdownBlock] {
        if let cached = self.blockCache.value(for: source) { return cached }
        let blocks = MarkdownBlock.parse(source)
        self.blockCache.set(blocks, for: source)
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        if let cached = self.inlineCache.value(for: text) { return cached }
        let parsed = MarkdownBlock.inline(text)
        self.inlineCache.set(parsed, for: text)
        return parsed
    }
}
