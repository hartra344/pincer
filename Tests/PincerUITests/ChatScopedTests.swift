import Testing
@testable import PincerUI

@MainActor
@Suite("ChatScoped")
struct ChatScopedTests {
    private final class Box { let n: Int; init(_ n: Int) { self.n = n } }

    @Test func sameKeyReusesTheValueWithoutMakingAnother() {
        let scoped = ChatScoped<Box>()
        var made = 0
        let first = scoped.value(for: "a") { made += 1; return Box(made) }
        let second = scoped.value(for: "a") { made += 1; return Box(made) }
        #expect(first === second)
        #expect(made == 1)
        #expect(scoped.takeRetired() == nil)
    }

    @Test func newKeyMakesFreshValueAndRetiresTheOldOnceOnly() {
        let scoped = ChatScoped<Box>()
        let a = scoped.value(for: "a") { Box(1) }
        let b = scoped.value(for: "b") { Box(2) }
        #expect(a !== b)
        #expect(scoped.key == "b")
        #expect(scoped.takeRetired() === a)
        #expect(scoped.takeRetired() == nil)
    }

    @Test func switchingBackMakesAFreshValue() {
        let scoped = ChatScoped<Box>()
        let a = scoped.value(for: "a") { Box(1) }
        _ = scoped.value(for: "b") { Box(2) }
        _ = scoped.takeRetired()
        let again = scoped.value(for: "a") { Box(3) }
        #expect(again !== a)
        #expect(again.n == 3)
    }
}
