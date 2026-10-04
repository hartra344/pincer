import Foundation
import Testing
@testable import PincerKit

@MainActor private final class RelayEngine: DictationEngine {
    let relay = DictationRecognitionDelivery()
    var active = false
    var isAvailable = true
    var callbacks: [@MainActor @Sendable (DictationRecognitionOutcome) -> Void] = []
    func authorize() async -> DictationIssue? { nil }
    func start(onPartial: @escaping @MainActor (String, Bool) -> Void, onError: @escaping @MainActor (DictationIssue) -> Void) throws {
        active = true
        callbacks.append(relay.begin(isActive: { [weak self] in self?.active == true }, onPartial: onPartial, onError: onError))
    }
    func stop() {}
    func cancel() { active = false }
}

@MainActor @Suite(.timeLimit(.minutes(2))) struct DictationRecognitionDeliveryTests {
    @Test func obsoleteCallbackCannotPoisonCurrentFinal() async throws {
        let engine = RelayEngine()
        let actual = DictationModel(engine: engine)
        defer { actual.cancel() }
        var draft = ""
        actual.toggle(draft: draft, caret: nil) { draft = $0 }
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while engine.callbacks.count < 1 {
            try Task.checkCancellation(); try #require(ContinuousClock.now < firstDeadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        let old = engine.callbacks[0]
        actual.cancel()
        actual.toggle(draft: draft, caret: nil) { draft = $0 }
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while engine.callbacks.count < 2 {
            try Task.checkCancellation(); try #require(ContinuousClock.now < secondDeadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        let current = engine.callbacks[1]
        current(.text("Current words", isFinal: false))
        try #require(draft == "Current words" && actual.isListening)
        old(.text("Obsolete words", isFinal: false))
        #expect(draft == "Current words", "Actual model rejects old generation partial")
        current(.ignorable)
        #expect(draft == "Current words", "Current final must not forward obsolete shared relay text")
        #expect(actual.phase == .idle)
    }
    @Test func ordinaryFinalErrorAndInactiveControls() {
        let relay = DictationRecognitionDelivery()
        var active = true, text = "", final = false
        var issue: DictationIssue?
        let callback = relay.begin(isActive: { active }, onPartial: { text = $0; final = $1 }, onError: { issue = $0 })
        callback(.text("Current", isFinal: false)); callback(.ignorable)
        #expect(text == "Current" && final)
        callback(.failure(.declined)); #expect(issue == .declined)
        active = false; callback(.text("Ignored", isFinal: false))
        #expect(text == "Current" && relay.lastText == "Current")
    }
}
