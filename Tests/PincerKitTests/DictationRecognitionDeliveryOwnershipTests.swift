import Testing
@testable import PincerKit

@MainActor @Suite struct DictationRecognitionDeliveryOwnershipTests {
    @Test func allObsoleteOutcomesAreRejectedBeforeMutation() {
        let relay = DictationRecognitionDelivery()
        var active = true, oldCalls = 0, currentCalls = 0
        var text = "", error: DictationIssue?
        let old = relay.begin(isActive: { active }, onPartial: { _, _ in oldCalls += 1 }, onError: { _ in oldCalls += 1 })
        old(.text("Initial", isFinal: false))
        #expect(relay.lastText == "Initial" && oldCalls == 1)
        let current = relay.begin(isActive: { active }, onPartial: { text = $0; currentCalls += 1; _ = $1 }, onError: { error = $0 })
        #expect(relay.lastText.isEmpty)
        current(.text("Current", isFinal: false))
        old(.text("Obsolete", isFinal: false)); old(.text("Obsolete final", isFinal: true))
        old(.failure(.declined)); old(.ignorable)
        #expect(oldCalls == 1 && relay.lastText == "Current" && currentCalls == 1)
        current(.ignorable); #expect(text == "Current" && currentCalls == 2)
        current(.failure(.declined)); #expect(error == .declined)
        active = false; current(.text("Inactive", isFinal: true))
        #expect(relay.lastText == "Current" && currentCalls == 2)
    }
}
