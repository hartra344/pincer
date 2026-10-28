import Foundation

extension DemoGateway {
    static let recoveryKey = "agent:main:dashboard:recovery"
    static let recoveryTitle = "Recovery check-in"
    static let recoveryPreview = "HRV averaged about 44 ms this week."

    /// The seeded "Recovery check-in" chat: the agent reads this device's Apple Health data through
    /// `pincer.health.query` (HRV statistics, then last night's sleep stages) from `HealthQuery.Fixture`.
    static func seedRecoveryTranscript(now: Date = Date(), calendar: Calendar = .current) -> [JSONValue] {
        let minute = 60.0
        let stamp = HealthQuery.Stamp(timeZone: calendar.timeZone)
        let today = HealthQuery.Fixture.today(now: now, calendar: calendar)
        let evening = calendar.date(byAdding: .hour, value: -6, to: today) ?? today
        let noon = calendar.date(byAdding: .hour, value: 12, to: today) ?? today
        let hrvParams = #"{"mode":"statistics","type":"heartRateVariabilitySDNN","interval":"day"}"#
        let sleepParams = #"{"type":"sleepAnalysis","startISO":"\#(stamp.string(evening))","endISO":"\#(stamp.string(noon))","sort":"asc","limit":200}"#
        func payload(_ params: String) -> String {
            guard case let .success(request) = HealthQuery.request(params, now: now, calendar: calendar),
                  case let .ok(json) = HealthQuery.Fixture.result(request, now: now, calendar: calendar)
            else { return "{}" }
            return json
        }
        func invoke(_ params: String) -> JSONValue {
            ["action": "invoke", "node": .string(Self.selfName), "invokeCommand": .string(HealthQuery.command),
             "invokeParamsJson": .string(params)]
        }
        let days = HealthQuery.Fixture.days(now: now, calendar: calendar)
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEEE"
        let lowDay = weekday.string(from: days[5])
        let hrvCall = "call_seed_health_hrv"
        let sleepCall = "call_seed_health_sleep"
        return [
            Self.message("user", [Self.text("How's my recovery this week? Check my HRV and last night's sleep.")],
                         id: "demo-recovery-ask", ago: 26 * minute),
            Self.message("assistant", [
                Self.thinking("I'll read daily HRV for the last week, then last night's sleep stages from their phone."),
                Self.toolCall(hrvCall, "nodes", invoke(hrvParams)),
            ], id: "demo-recovery-hrv", ago: 26 * minute - 4),
            Self.message("toolResult", [Self.text(payload(hrvParams))], ago: 26 * minute - 6,
                         extra: ["toolCallId": .string(hrvCall), "toolName": "nodes", "isError": false]),
            Self.message("assistant", [Self.toolCall(sleepCall, "nodes", invoke(sleepParams))],
                         id: "demo-recovery-sleep", ago: 26 * minute - 8),
            Self.message("toolResult", [Self.text(payload(sleepParams))], ago: 26 * minute - 10,
                         extra: ["toolCallId": .string(sleepCall), "toolName": "nodes", "isError": false]),
            Self.message("assistant", [Self.text("""
            Your recovery looks steady this week.

            - **HRV** averaged about **44 ms** (SDNN). The low was **35.9 ms** on \(lowDay), right after \
            the late night, and it bounced back to 44.1 ms this morning.
            - **Last night** you were in bed 22:48–06:31 and asleep for **6 h 31 min**: 62 min deep, \
            1 h 38 min REM and 3 h 51 min core, with 14 min awake.
            - **Resting heart rate** held at 56–60 bpm.

            Another early night would help, and an easy day after a short night keeps HRV up. \
            This is a read of your Apple Health data, not medical advice.
            """)], id: "demo-recovery-reply", ago: 25 * minute),
        ]
    }
}
