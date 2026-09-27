import Testing
@testable import PincerKit

@Suite("Composer Return key")
struct ComposerReturnTests {
    @Test("full truth table", arguments: [false, true], [false, true])
    func truthTable(command: Bool, supportsSendAndOpen: Bool) {
        for shift in [false, true] {
            for option in [false, true] {
                let action = ComposerReturnAction.resolve(shift: shift, option: option, command: command,
                                                          supportsSendAndOpen: supportsSendAndOpen)
                let expected: ComposerReturnAction =
                    shift || option ? .newline : (command && supportsSendAndOpen ? .sendAndOpen : .send)
                #expect(action == expected, "shift=\(shift) option=\(option) command=\(command) supports=\(supportsSendAndOpen)")
            }
        }
    }

    @Test("Quick Capture: ⌘↩ sends and opens, ↩ sends")
    func quickCapture() {
        #expect(ComposerReturnAction.resolve(shift: false, option: false, command: true, supportsSendAndOpen: true) == .sendAndOpen)
        #expect(ComposerReturnAction.resolve(shift: false, option: false, command: false, supportsSendAndOpen: true) == .send)
    }

    @Test("main composer: ⌘↩ still just sends")
    func mainComposer() {
        #expect(ComposerReturnAction.resolve(shift: false, option: false, command: true, supportsSendAndOpen: false) == .send)
        #expect(ComposerReturnAction.resolve(shift: false, option: false, command: false, supportsSendAndOpen: false) == .send)
    }

    @Test("shift or option inserts a newline even with ⌘")
    func newlineWins() {
        #expect(ComposerReturnAction.resolve(shift: true, option: false, command: true, supportsSendAndOpen: true) == .newline)
        #expect(ComposerReturnAction.resolve(shift: false, option: true, command: true, supportsSendAndOpen: true) == .newline)
        #expect(ComposerReturnAction.resolve(shift: true, option: true, command: false, supportsSendAndOpen: false) == .newline)
    }
}
