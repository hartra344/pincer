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

@Suite("Composer Return key source (#567)")
struct ComposerReturnKeyTests {
    private func resolve(
        _ source: ComposerReturnKey.Source, marked: Bool = false, shift: Bool = false, option: Bool = false,
        command: Bool = false, canSubmit: Bool = true) -> ComposerReturnKey
    {
        ComposerReturnKey.resolve(
            source: source, hasMarkedText: marked, shift: shift, option: option, command: command,
            supportsSendAndOpen: false, canSubmit: canSubmit)
    }

    @Test("hardware ↩ sends, ⇧↩ and ⌥↩ insert a newline")
    func hardware() {
        #expect(self.resolve(.hardware) == .send)
        #expect(self.resolve(.hardware, command: true) == .send)
        #expect(self.resolve(.hardware, shift: true) == .newline)
        #expect(self.resolve(.hardware, option: true) == .newline)
    }

    @Test("the on-screen keyboard's Return is always left to the text system", arguments: [false, true], [false, true])
    func software(shift: Bool, canSubmit: Bool) {
        #expect(self.resolve(.software, shift: shift, canSubmit: canSubmit) == .system)
        #expect(self.resolve(.software, marked: true, shift: shift, canSubmit: canSubmit) == .system)
    }

    @Test("Return while composing marked text commits the candidate, never sends", arguments: [false, true])
    func markedText(shift: Bool) {
        #expect(self.resolve(.hardware, marked: true, shift: shift) == .system)
        #expect(self.resolve(.hardware, marked: true, command: true) == .system)
    }

    @Test("an empty or unsendable draft swallows ↩ instead of sending; ⇧↩ still inserts a newline")
    func cannotSubmit() {
        #expect(self.resolve(.hardware, canSubmit: false) == .ignore)
        #expect(self.resolve(.hardware, command: true, canSubmit: false) == .ignore)
        #expect(self.resolve(.hardware, shift: true, canSubmit: false) == .newline)
        #expect(ComposerReturnKey.resolve(
            source: .hardware, hasMarkedText: false, shift: false, option: false, command: true,
            supportsSendAndOpen: true, canSubmit: false) == .ignore)
    }

    @Test("Quick Capture keeps ⌘↩ as Send & Open")
    func quickCapture() {
        #expect(ComposerReturnKey.resolve(
            source: .hardware, hasMarkedText: false, shift: false, option: false, command: true,
            supportsSendAndOpen: true, canSubmit: true) == .sendAndOpen)
    }
}
