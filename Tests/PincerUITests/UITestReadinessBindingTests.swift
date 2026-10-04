#if DEBUG
import Testing

@MainActor
@Suite("Actual UI readiness cancellation binding", .timeLimit(.minutes(2)))
struct UITestReadinessBindingTests {
    @Test func actualEventuallyRefusesPreCanceledPredicate() async {
        var calls = 0
        let task = Task { await eventually(timeout: .milliseconds(20)) { calls += 1; return true } }
        task.cancel()
        let result = await task.value
        #expect(!result && calls == 0)
    }
}
#endif
