import Testing
@testable import PincerKit

@MainActor
struct BoundedMetadataFIFOTests {
    @Test func realAdmissionRejectsOverflowAndRecyclesCancelledDescriptors() {
        let queue = BoundedMetadataFIFO<Int>(limit: 64)
        for value in 0..<64 { #expect(queue.append(value)) }
        #expect(!queue.append(64) && queue.count == 64)
        queue.removeAll { $0.isMultiple(of: 2) }
        #expect(queue.count == 32 && queue.popFirst() == 1)
        #expect(queue.append(64))
        var drained: [Int] = []
        while let next = queue.popFirst() { drained.append(next) }
        #expect(drained.last == 64 && drained.count == 32 && queue.count == 0)
    }
}
