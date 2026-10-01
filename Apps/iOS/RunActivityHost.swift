import ActivityKit
import Foundation
import PincerKit

/// Shows `RunActivityCoordinator`'s activities with ActivityKit. Updates are local: they continue while
/// iOS keeps Pincer running, and the card keeps counting up by itself either way.
@MainActor
final class ActivityKitRunHost: RunActivityHost {
    private var activities: [String: Activity<PincerRunAttributes>] = [:]

    init() {
        // A card left over from a launch that was killed mid-turn has nothing driving it.
        for activity in Activity<PincerRunAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(_ identity: RunActivityIdentity, state: RunActivityState) -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        do {
            let activity = try Activity.request(
                attributes: PincerRunAttributes(identity: identity),
                content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            self.activities[activity.id] = activity
            return activity.id
        } catch {
            // Typically the app isn't in the foreground, or too many activities are already showing.
            NSLog("[Pincer] Live Activity not started: %@", error.localizedDescription)
            return nil
        }
    }

    func update(id: String, state: RunActivityState) {
        guard let activity = self.activities[id] else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end(id: String, state: RunActivityState, dismissAfter: TimeInterval) {
        guard let activity = self.activities.removeValue(forKey: id) else { return }
        let policy: ActivityUIDismissalPolicy = dismissAfter > 0 ? .after(Date().addingTimeInterval(dismissAfter)) : .immediate
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
    }
}
