import PincerKit

@MainActor func runDictationRecognitionOwnershipChecks() {
    let relay = DictationRecognitionDelivery()
    var active = true, oldCalls = 0, currentCalls = 0
    var text = "", issue: DictationIssue?
    let old = relay.begin(isActive: { active }, onPartial: { _, _ in oldCalls += 1 }, onError: { _ in oldCalls += 1 })
    old(.text("Initial", isFinal: false))
    let current = relay.begin(isActive: { active }, onPartial: { text = $0; currentCalls += 1; _ = $1 }, onError: { issue = $0 })
    check(relay.lastText.isEmpty, "current recognition begin resets its own text")
    current(.text("Current", isFinal: false))
    old(.text("Obsolete", isFinal: false)); old(.text("Obsolete final", isFinal: true))
    old(.failure(.declined)); old(.ignorable)
    check(oldCalls == 1 && relay.lastText == "Current" && currentCalls == 1, "all obsolete outcomes are rejected before text or callbacks change")
    current(.ignorable); current(.failure(.declined))
    check(text == "Current" && currentCalls == 2 && issue == .declined, "current final and error remain supported")
    active = false; current(.text("Inactive", isFinal: true))
    check(relay.lastText == "Current" && currentCalls == 2, "inactive current delivery remains ignored")
}
