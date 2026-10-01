import Testing
@testable import PincerKit

struct ComposerTabActionTests {
    @Test(arguments: [
        (false, false, false, false, ComposerTabAction.nextKeyView),
        (false, true, false, false, ComposerTabAction.previousKeyView),
        (true, false, false, false, ComposerTabAction.acceptSuggestion),
        (true, true, false, false, ComposerTabAction.system),
        (false, false, true, false, ComposerTabAction.insertLiteralTab),
        (true, false, true, false, ComposerTabAction.insertLiteralTab),
        (false, true, true, false, ComposerTabAction.system),
        (true, true, true, false, ComposerTabAction.system),
        (false, false, false, true, ComposerTabAction.system),
        (true, false, false, true, ComposerTabAction.system),
        (false, true, false, true, ComposerTabAction.system),
        (true, true, false, true, ComposerTabAction.system),
        (false, false, true, true, ComposerTabAction.system),
        (true, false, true, true, ComposerTabAction.system),
        (false, true, true, true, ComposerTabAction.system),
        (true, true, true, true, ComposerTabAction.system),
    ])
    func resolver(menuActive: Bool, backwards: Bool, optionPressed: Bool, hasMarkedText: Bool, expected: ComposerTabAction) {
        #expect(ComposerTabAction.resolve(menuActive: menuActive, backwards: backwards,
                                          optionPressed: optionPressed, hasMarkedText: hasMarkedText) == expected)
    }
}
