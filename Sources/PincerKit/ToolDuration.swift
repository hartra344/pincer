import Foundation

/// How a tool's run time reads in a card: "340 ms", "1.2 s", "2 m 05 s".
public enum ToolDuration {
    /// The short text and how VoiceOver says it ("Took 1.2 seconds").
    public static func format(_ ms: Int) -> (text: String, spoken: String) {
        if ms < 1000 { return ("\(ms) ms", L("Took \(ms) milliseconds")) }
        if ms < 60_000 {
            var number = String(format: "%.1f", Double(ms) / 1000)
            if number.hasSuffix(".0") { number.removeLast(2) }
            return ("\(number) s", L("Took \(number) seconds"))
        }
        let seconds = ms / 1000
        let text = String(format: "%d m %02d s", seconds / 60, seconds % 60)
        let minutes = seconds / 60
        let rest = seconds % 60
        let spoken = switch (minutes, rest) {
        case (1, 0): L("Took 1 minute")
        case (_, 0): L("Took \(minutes) minutes")
        case (1, 1): L("Took 1 minute 1 second")
        case (1, _): L("Took 1 minute \(rest) seconds")
        case (_, 1): L("Took \(minutes) minutes 1 second")
        default: L("Took \(minutes) minutes \(rest) seconds")
        }
        return (text, spoken)
    }
}
