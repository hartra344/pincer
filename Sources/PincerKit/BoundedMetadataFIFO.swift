/// Count-bounded waiting descriptors. Callers keep payloads out of these descriptors and acquire
/// their expensive source only after removing a descriptor for the single active worker.
@MainActor
package final class BoundedMetadataFIFO<Element> {
    package let limit: Int
    private var elements: [Element] = []
    package init(limit: Int) { self.limit = max(0, limit) }
    package var count: Int { self.elements.count }
    package func append(_ element: Element) -> Bool {
        guard self.elements.count < self.limit else { return false }
        self.elements.append(element)
        return true
    }
    package func popFirst() -> Element? {
        self.elements.isEmpty ? nil : self.elements.removeFirst()
    }
    package func removeAll(where predicate: (Element) -> Bool) {
        self.elements.removeAll(where: predicate)
    }
}
