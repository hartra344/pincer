import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

@MainActor
func runStreamingClockChecks() {
    #if DEBUG
    let frame = 1.0 / 60.0
    let delayAfterBackwardAdjustment = ChatStore.coalescedFlushDelay(interval: frame, elapsed: -3_600)
    check(abs(delayAfterBackwardAdjustment - frame) < 0.000_001,
          "stream clock: backward wall-clock adjustment is bounded to one frame")
    check(abs(ChatStore.coalescedFlushDelay(interval: frame, elapsed: 0) - frame) < 0.000_001,
          "stream clock: a same-instant burst waits one frame")
    check(abs(ChatStore.coalescedFlushDelay(interval: frame, elapsed: frame / 2) - frame / 2) < 0.000_001,
          "stream clock: normal elapsed time preserves the remaining coalescing window")
    check(ChatStore.coalescedFlushDelay(interval: frame, elapsed: frame) == 0,
          "stream clock: an elapsed frame is due immediately")
    #endif
}
