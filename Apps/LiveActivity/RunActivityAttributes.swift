import ActivityKit
import Foundation
import PincerKit

/// A running agent turn on the Lock Screen and in the Dynamic Island. Compiled into both the app,
/// which starts and updates the activity, and the Live Activity extension, which draws it.
struct PincerRunAttributes: ActivityAttributes {
    typealias ContentState = RunActivityState

    /// Which chat the turn belongs to; fixed for the activity's lifetime.
    var identity: RunActivityIdentity
}
