import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct FilePreviewExtensionPolicyTests {
    @Test(arguments: [119, 120, 130])
    func oversizedExtensionReservesVisibleStem(length: Int) async {
        let value = await Task.detached {
            FilePreviewFiles.fileName("attachment." + String(repeating: "x", count: length), mimeType: nil)
        }.value
        #expect(value == "a." + String(repeating: "x", count: 118))
    }
    @Test func unicodeExtensionUsesExistingCharacterBudget() async {
        let value = await Task.detached {
            FilePreviewFiles.fileName("📘." + String(repeating: "é", count: 130), mimeType: nil)
        }.value
        #expect(value == "📘." + String(repeating: "é", count: 118))
        #expect(value.count == 120)
    }
}
