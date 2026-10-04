#if DEBUG
import Testing
@testable import PincerKit

struct AvatarPhaseDiagnosticsTests {
    @Test func fixedSnapshotBoundsAndReplacement() {
        let value = AvatarPhaseDiagnostics()
        value.enter(.overlays, ready: true, width: .infinity, height: .greatestFiniteMagnitude)
        #expect(value.report().contains("width=0.0 height=10000.0"))
        value.enter(.history)
        #expect(value.report().contains("phase=history"))
        #expect(!value.report().contains("phase=overlays"))
        #expect(value.report().utf8.count < 180)
    }
}
#endif
