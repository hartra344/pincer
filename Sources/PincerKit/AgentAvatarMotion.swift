import Foundation

/// One frame of the avatar, in the creature's 16×16 pixel grid. Pixel art moves in whole pixels;
/// plush drawing uses the same values, plus `tilt` and `squash`.
public struct AvatarPose: Hashable, Sendable {
    public enum Eyes: String, Hashable, Sendable {
        /// Tiny dots; `closed` is a flat line, `happy` a little ^.
        case open, closed, happy
    }

    public enum Arm: Hashable, Sendable {
        case down
        /// Lifted 1px, as when tapping along.
        case tap
        /// Raised above the shoulder; `wave` shifts it outward by its value (0 or 1).
        case up(wave: Int)
    }

    /// Vertical offset, negative is up.
    public var bob = 0
    /// Horizontal offset.
    public var sway = 0
    /// Degrees, for plush only.
    public var tilt: Double = 0
    /// Width multiplier for squash and stretch; height gets the inverse. 1 is none.
    public var squash: Double = 1
    public var eyes = Eyes.open
    /// Eyes' vertical offset, negative is looking up.
    public var gaze = 0
    public var leftArm = Arm.down
    public var rightArm = Arm.down
    /// Offset of the top feature (tufts, leaves, stones, antenna) for a twitch.
    public var twitch = 0
    /// "…" bubble: 0 hides it, 1–3 shows that many dots.
    public var bubbleDots = 0
    /// Floating "z", rising from 0 to 1; nil hides it.
    public var zRise: Double?
    public var sweat = false
    /// Tiny 1px "u".
    public var mouth = false

    public init() {}
}

/// Pet-like motion for each state. Pure: callers pass the clock.
public enum AvatarMotion {
    /// A blink lasts this long.
    public static let blinkDuration: TimeInterval = 0.12
    /// Blinks come once per cycle at a varying offset, so gaps between them run 4–7 s.
    static let blinkCycle: TimeInterval = 5.5
    static let blinkJitter: TimeInterval = 1.5
    /// Idle breathing moves 1px every this long.
    public static let breathPeriod: TimeInterval = 1.8
    /// Success hop and error wobble play once, over this long, then hold.
    public static let hopDuration: TimeInterval = 0.6
    public static let wobbleDuration: TimeInterval = 0.9

    /// The frame to draw.
    /// - Parameters:
    ///   - time: The clock, e.g. `timeIntervalSinceReferenceDate`; drives blinks and breathing.
    ///   - elapsed: Seconds since the avatar entered `state`; drives one-shot moves.
    ///   - animated: False gives each state's static key pose (Reduce Motion, or animation off).
    ///   - phase: Per-avatar offset so several avatars don't blink in sync (see `phase(for:)`).
    public static func pose(
        for state: AvatarState, time: TimeInterval, elapsed: TimeInterval, animated: Bool, phase: TimeInterval = 0)
        -> AvatarPose
    {
        guard animated else { return self.keyPose(for: state) }
        var pose = AvatarPose()
        let blinking = self.isBlinking(at: time, phase: phase)
        if blinking { pose.eyes = .closed }
        let step = Int(floor(max(elapsed, 0) / 0.125))
        switch state {
        case .idle:
            pose.bob = self.breathOffset(at: time)
        case .thinking:
            pose.bob = [0, -1, -2, -1][step % 4]
            pose.gaze = -1
            pose.bubbleDots = 1 + (step / 3) % 3
        case .streaming:
            pose.sway = [0, 1, 0, -1][(step / 2) % 4]
            pose.rightArm = step % 2 == 0 ? .tap : .down
            pose.mouth = true
        case .tool:
            pose.twitch = [0, 1, 0, 0, 1, 0, 0, 0][step % 8]
            pose.bob = self.breathOffset(at: time)
        case .awaitingApproval:
            pose.leftArm = .up(wave: (step / 2) % 2)
        case .success:
            pose.eyes = .happy
            pose.mouth = true
            let t = max(elapsed, 0)
            if t < 0.1 {
                pose.squash = 1.15
            } else if t < 0.5 {
                // Parabolic arc up to 3px and back down.
                let x = (t - 0.1) / 0.4
                pose.bob = -Int((12 * x * (1 - x)).rounded())
                pose.squash = 0.9
                pose.leftArm = .up(wave: 0)
                pose.rightArm = .up(wave: 0)
            } else if t < self.hopDuration {
                pose.squash = 1.1
            }
        case .error:
            pose.sweat = true
            pose.gaze = 1
            let t = max(elapsed, 0)
            if t < self.wobbleDuration {
                let tilts = [-1, 1, -1, 1, -1, 1]
                let index = min(Int(t / (self.wobbleDuration / Double(tilts.count))), tilts.count - 1)
                pose.sway = tilts[index]
                pose.tilt = Double(tilts[index]) * 8
            } else {
                // Settles into the worried lean of the still pose.
                pose.sway = 1
                pose.tilt = 6
            }
        case .compacting:
            pose.eyes = .closed
            pose.bob = 1 + self.breathOffset(at: time * 0.6)
            // In eighths, so frames between steps draw the same pose and can be skipped.
            pose.zRise = (max(elapsed, 0).truncatingRemainder(dividingBy: 2) * 4).rounded(.down) / 8
        }
        return pose
    }

    /// The pose held in each state when not animating.
    public static func keyPose(for state: AvatarState) -> AvatarPose {
        var pose = AvatarPose()
        switch state {
        case .idle: break
        case .thinking:
            pose.gaze = -1
            pose.bubbleDots = 3
        case .streaming:
            pose.rightArm = .tap
            pose.mouth = true
        case .tool: pose.twitch = 1
        case .awaitingApproval: pose.leftArm = .up(wave: 0)
        case .success:
            pose.eyes = .happy
            pose.mouth = true
            pose.leftArm = .up(wave: 0)
            pose.rightArm = .up(wave: 0)
        case .error:
            // Worried: leaning over, eyes lowered, a sweat drop.
            pose.sweat = true
            pose.sway = 1
            pose.tilt = 6
            pose.gaze = 1
        case .compacting:
            pose.eyes = .closed
            pose.bob = 1
            pose.zRise = 0.5
        }
        return pose
    }

    /// Seconds between frames while animating `state`, or nil when only blinks and breathing
    /// change it (use `nextIdleChange`).
    public static func frameInterval(for state: AvatarState, plush: Bool) -> TimeInterval? {
        switch state {
        case .idle: nil
        // Low on purpose: pixel poses step in whole cells, and plush reads fine at 10fps.
        default: plush ? 0.1 : 0.125
        }
    }

    /// Next moment an idle pose changes (a blink starting or ending, or a breath), after `time`.
    public static func nextIdleChange(after time: TimeInterval, phase: TimeInterval = 0) -> TimeInterval {
        let breath = (floor(time / self.breathPeriod) + 1) * self.breathPeriod
        let cycle = floor((time - phase) / self.blinkCycle)
        var candidates = [breath]
        for n in [cycle, cycle + 1] {
            let start = self.blinkStart(cycle: n, phase: phase)
            candidates += [start, start + self.blinkDuration]
        }
        return candidates.filter { $0 > time }.min() ?? breath
    }

    /// Whether the eyes are shut for a blink at `time`.
    public static func isBlinking(at time: TimeInterval, phase: TimeInterval = 0) -> Bool {
        let start = self.blinkStart(cycle: floor((time - phase) / self.blinkCycle), phase: phase)
        return time >= start && time < start + self.blinkDuration
    }

    /// A stable per-avatar phase in 0..<blinkCycle, from a seed such as the agent id.
    public static func phase(for seed: String) -> TimeInterval {
        Double(AvatarStyle.fnv1a(seed) % 5500) / 1000
    }

    static func blinkStart(cycle n: Double, phase: TimeInterval) -> TimeInterval {
        let jitter = Double(AvatarStyle.fnv1a("blink\(Int(n))") % 1500) / 1000
        return phase + n * self.blinkCycle + jitter
    }

    static func breathOffset(at time: TimeInterval) -> Int {
        Int(floor(time / self.breathPeriod)) % 2 == 0 ? 0 : -1
    }
}
