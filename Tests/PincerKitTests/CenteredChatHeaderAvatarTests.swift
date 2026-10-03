import Foundation
import Testing
@testable import PincerKit

@Suite("Chat identity still avatar poses")
struct CenteredChatHeaderAvatarTests {
    @Test(arguments: [AvatarState.idle, .thinking, .streaming, .tool(.exec), .awaitingApproval, .success, .error, .compacting])
    func nonAnimatedAvatarRetainsMeaningfulStateWithoutClockMotion(_ state: AvatarState) {
        let first = AvatarMotion.pose(for: state, time: 0, elapsed: 0, animated: false, phase: 0)
        let later = AvatarMotion.pose(for: state, time: 10_000, elapsed: 10_000, animated: false, phase: 4)
        #expect(first == later && first == AvatarMotion.keyPose(for: state))
        if state == .awaitingApproval { #expect(first.leftArm == .up(wave: 0)) }
        if state == .error { #expect(first.sweat && first.gaze == 1) }
        if state == .thinking { #expect(first.bubbleDots == 3) }
    }
}
