import Foundation

/// `pincer.health.query`: a Pincer-only, read-only node command (owner decision, #1084) that the
/// Gateway forwards only when `gateway.nodes.commands.allow` lists it. One command with three modes:
/// `types` (discovery), `samples` (individual readings) and `statistics` (buckets over a range).
/// PincerUI runs the HealthKit queries; the catalog, params, ranges, rounding, category bucketing,
/// payloads and the demo fixture live here so tests and checks cover them on any platform.
public enum HealthQuery {
    public static let command = "pincer.health.query"

    public static let maxSpanDays = 1827
    public static let maxBuckets = 500
    public static let maxLimit = 1000
    public static let defaultLimit = 100
    // periphery:ignore - read only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public static let maxCategorySamples = 20000
    /// `openclaw nodes invoke --invoke-timeout` defaults to 15 s.
    public static let defaultTimeoutMs = 15000

    public static let allowedParams = ["mode", "type", "startISO", "endISO", "interval", "limit", "sort"]

    public static let usage = """
        pincer.health.query params: {"type":"heartRateVariabilitySDNN","mode":"samples|statistics",\
        "startISO":"2026-10-21","endISO":"2026-10-28","interval":"day","limit":100,"sort":"desc"}
        """

    /// What `types` lists as never shared.
    public static let excluded = [
        "clinicalRecords", "documents", "medications", "visionPrescriptions", "characteristics",
        "workoutRoutes", "heartbeatSeries",
    ]

    public enum Mode: String, Codable, Sendable, CaseIterable {
        case types, samples, statistics
    }

    public enum Interval: String, Codable, Sendable, CaseIterable {
        case hour, day, week, month, total
    }

    public enum Sort: String, Codable, Sendable, CaseIterable {
        case desc, asc
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case quantity, category, correlation, workout, electrocardiogram, audiogram, stateOfMind,
             scoredAssessment, activitySummary

        /// Order of the `types` list: quantities, categories, correlations, then the rest.
        var rank: Int {
            switch self {
            case .quantity: 0
            case .category: 1
            case .correlation: 2
            default: 3
            }
        }
    }

    public enum Aggregation: String, Codable, Sendable {
        /// `HKStatisticsOptions.cumulativeSum` → bucket `sum`.
        case cumulative
        /// `.discreteAverage | .discreteMin | .discreteMax` → `average`, `min`, `max`.
        case discrete
    }

    public struct CategoryValue: Sendable, Hashable {
        public let raw: Int
        public let name: String
    }

    /// One shareable HealthKit type. `identifier` is the runtime `HKObjectType.identifier`; PincerUI
    /// resolves it at run time and drops entries this OS doesn't know.
    public struct Entry: Sendable, Hashable {
        public let name: String
        public let identifier: String
        public let kind: Kind
        /// The fixed unit values are reported in; `%` types are reported 0–100.
        public let unit: String?
        public let aggregation: Aggregation?
        /// Named values for category types; `nil` for `HKCategoryValue` (not applicable) types.
        public let values: [CategoryValue]?

        public var isPercent: Bool { self.unit == "%" }

        public func valueName(_ raw: Int) -> String? {
            guard let values else { return nil }
            return values.first { $0.raw == raw }?.name ?? "unknown(\(raw))"
        }
    }

    // MARK: Catalog

    /// Every `HKQuantityTypeIdentifier` (iOS 27.1 SDK) with its canonical unit and aggregation style
    /// from the header comments; `heartRate`/`respiratoryRate` use count/min and `uvExposure` count.
    /// `nikeFuel` is left out: a legacy Nike-only type, and an unreadable type in the authorization set
    /// would raise an Objective-C exception.
    private static let quantitySpecs: [(String, String, Aggregation)] = [
        ("AppleSleepingWristTemperature", "degC", .discrete), ("BodyFatPercentage", "%", .discrete),
        ("BodyMass", "kg", .discrete), ("BodyMassIndex", "count", .discrete),
        ("ElectrodermalActivity", "S", .discrete), ("Height", "m", .discrete), ("LeanBodyMass", "kg", .discrete),
        ("WaistCircumference", "m", .discrete),
        ("ActiveEnergyBurned", "kcal", .cumulative), ("AppleExerciseTime", "min", .cumulative),
        ("AppleMoveTime", "min", .cumulative), ("AppleStandTime", "min", .cumulative),
        ("BasalEnergyBurned", "kcal", .cumulative), ("CrossCountrySkiingSpeed", "m/s", .discrete),
        ("CyclingCadence", "count/min", .discrete), ("CyclingFunctionalThresholdPower", "W", .discrete),
        ("CyclingPower", "W", .discrete), ("CyclingSpeed", "m/s", .discrete),
        ("DistanceCrossCountrySkiing", "m", .cumulative), ("DistanceCycling", "m", .cumulative),
        ("DistanceDownhillSnowSports", "m", .cumulative), ("DistancePaddleSports", "m", .cumulative),
        ("DistanceRowing", "m", .cumulative), ("DistanceSkatingSports", "m", .cumulative),
        ("DistanceSwimming", "m", .cumulative), ("DistanceWalkingRunning", "m", .cumulative),
        ("DistanceWheelchair", "m", .cumulative), ("EstimatedWorkoutEffortScore", "appleEffortScore", .discrete),
        ("FlightsClimbed", "count", .cumulative),
        ("PaddleSportsSpeed", "m/s", .discrete), ("PhysicalEffort", "kcal/(kg*hr)", .discrete),
        ("PushCount", "count", .cumulative), ("RowingSpeed", "m/s", .discrete), ("RunningPower", "W", .discrete),
        ("RunningSpeed", "m/s", .discrete), ("StepCount", "count", .cumulative),
        ("SwimmingStrokeCount", "count", .cumulative), ("UnderwaterDepth", "m", .discrete),
        ("WorkoutEffortScore", "appleEffortScore", .discrete),
        ("EnvironmentalAudioExposure", "dBASPL", .discrete), ("EnvironmentalSoundReduction", "dBASPL", .discrete),
        ("HeadphoneAudioExposure", "dBASPL", .discrete),
        ("AtrialFibrillationBurden", "%", .discrete), ("HeartRate", "count/min", .discrete),
        ("HeartRateRecoveryOneMinute", "count/min", .discrete), ("HeartRateVariabilityRMSSD", "ms", .discrete),
        ("HeartRateVariabilitySDNN", "ms", .discrete), ("PeripheralPerfusionIndex", "%", .discrete),
        ("RestingHeartRate", "count/min", .discrete), ("VO2Max", "ml/(kg*min)", .discrete),
        ("WalkingHeartRateAverage", "count/min", .discrete),
        ("AppleWalkingSteadiness", "%", .discrete), ("RunningGroundContactTime", "ms", .discrete),
        ("RunningStrideLength", "m", .discrete), ("RunningVerticalOscillation", "cm", .discrete),
        ("SixMinuteWalkTestDistance", "m", .discrete), ("StairAscentSpeed", "m/s", .discrete),
        ("StairDescentSpeed", "m/s", .discrete), ("WalkingAsymmetryPercentage", "%", .discrete),
        ("WalkingDoubleSupportPercentage", "%", .discrete), ("WalkingSpeed", "m/s", .discrete),
        ("WalkingStepLength", "m", .discrete),
        ("DietaryBiotin", "g", .cumulative), ("DietaryCaffeine", "g", .cumulative),
        ("DietaryCalcium", "g", .cumulative), ("DietaryCarbohydrates", "g", .cumulative),
        ("DietaryChloride", "g", .cumulative), ("DietaryCholesterol", "g", .cumulative),
        ("DietaryChromium", "g", .cumulative), ("DietaryCopper", "g", .cumulative),
        ("DietaryEnergyConsumed", "kcal", .cumulative), ("DietaryFatMonounsaturated", "g", .cumulative),
        ("DietaryFatPolyunsaturated", "g", .cumulative), ("DietaryFatSaturated", "g", .cumulative),
        ("DietaryFatTotal", "g", .cumulative), ("DietaryFiber", "g", .cumulative),
        ("DietaryFolate", "g", .cumulative), ("DietaryIodine", "g", .cumulative), ("DietaryIron", "g", .cumulative),
        ("DietaryMagnesium", "g", .cumulative), ("DietaryManganese", "g", .cumulative),
        ("DietaryMolybdenum", "g", .cumulative), ("DietaryNiacin", "g", .cumulative),
        ("DietaryPantothenicAcid", "g", .cumulative), ("DietaryPhosphorus", "g", .cumulative),
        ("DietaryPotassium", "g", .cumulative), ("DietaryProtein", "g", .cumulative),
        ("DietaryRiboflavin", "g", .cumulative), ("DietarySelenium", "g", .cumulative),
        ("DietarySodium", "g", .cumulative), ("DietarySugar", "g", .cumulative), ("DietaryThiamin", "g", .cumulative),
        ("DietaryVitaminA", "g", .cumulative), ("DietaryVitaminB12", "g", .cumulative),
        ("DietaryVitaminB6", "g", .cumulative), ("DietaryVitaminC", "g", .cumulative),
        ("DietaryVitaminD", "g", .cumulative), ("DietaryVitaminE", "g", .cumulative),
        ("DietaryVitaminK", "g", .cumulative), ("DietaryWater", "mL", .cumulative), ("DietaryZinc", "g", .cumulative),
        ("BloodAlcoholContent", "%", .discrete), ("BloodPressureDiastolic", "mmHg", .discrete),
        ("BloodPressureSystolic", "mmHg", .discrete), ("InsulinDelivery", "IU", .cumulative),
        ("NumberOfAlcoholicBeverages", "count", .cumulative), ("NumberOfTimesFallen", "count", .cumulative),
        ("TimeInDaylight", "min", .cumulative), ("UVExposure", "count", .discrete),
        ("WaterTemperature", "degC", .discrete), ("BasalBodyTemperature", "degC", .discrete),
        ("AppleSleepingBreathingDisturbances", "count", .discrete), ("ForcedExpiratoryVolume1", "L", .discrete),
        ("ForcedVitalCapacity", "L", .discrete), ("InhalerUsage", "count", .cumulative),
        ("OxygenSaturation", "%", .discrete), ("PeakExpiratoryFlowRate", "L/min", .discrete),
        ("RespiratoryRate", "count/min", .discrete),
        ("BloodGlucose", "mg/dL", .discrete), ("BodyTemperature", "degC", .discrete),
    ]

    private static func values(_ names: [String], from first: Int) -> [CategoryValue] {
        names.enumerated().map { CategoryValue(raw: first + $0.offset, name: $0.element) }
    }

    private static let severity = values(["unspecified", "notPresent", "mild", "moderate", "severe"], from: 0)
    private static let presence = values(["present", "notPresent"], from: 0)
    private static let vaginalBleeding = values(["unspecified", "light", "medium", "heavy", "none"], from: 1)
    private static let testResult = values(["negative", "positive", "indeterminate"], from: 1)

    /// Every `HKCategoryTypeIdentifier` except the deprecated `audioExposureEvent`, with the value
    /// enum names from HKCategoryValues.h (`nil` = `HKCategoryValue`, not applicable).
    private static let categorySpecs: [(String, [CategoryValue]?)] = [
        ("AppleStandHour", values(["stood", "idle"], from: 0)),
        ("EnvironmentalAudioExposureEvent", values(["momentaryLimit"], from: 1)),
        ("HeadphoneAudioExposureEvent", values(["sevenDayLimit"], from: 1)),
        ("HighHeartRateEvent", nil), ("HypertensionEvent", nil), ("IrregularHeartRhythmEvent", nil),
        ("LowCardioFitnessEvent", values(["lowFitness"], from: 1)), ("LowHeartRateEvent", nil),
        ("MindfulSession", nil),
        ("AppleWalkingSteadinessEvent", values(["initialLow", "initialVeryLow", "repeatLow", "repeatVeryLow"], from: 1)),
        ("HandwashingEvent", nil), ("ToothbrushingEvent", nil),
        ("BleedingAfterMenopause", vaginalBleeding), ("BleedingAfterPregnancy", vaginalBleeding),
        ("BleedingDuringPregnancy", vaginalBleeding),
        ("CervicalMucusQuality", values(["dry", "sticky", "creamy", "watery", "eggWhite"], from: 1)),
        ("Contraceptive", values(
            ["unspecified", "implant", "injection", "intrauterineDevice", "intravaginalRing", "oral", "patch"], from: 1)),
        ("InfrequentMenstrualCycles", nil), ("IntermenstrualBleeding", nil), ("IrregularMenstrualCycles", nil),
        ("Lactation", nil), ("MenopausalState", values(["menopause", "perimenopause", "none"], from: 1)),
        ("MenstrualFlow", vaginalBleeding),
        ("OvulationTestResult", values(["negative", "luteinizingHormoneSurge", "indeterminate", "estrogenSurge"], from: 1)),
        ("PersistentIntermenstrualBleeding", nil), ("Pregnancy", nil), ("PregnancyTestResult", testResult),
        ("ProgesteroneTestResult", testResult), ("ProlongedMenstrualPeriods", nil), ("SexualActivity", nil),
        ("SleepApneaEvent", nil),
        ("SleepAnalysis", values(["inBed", "asleepUnspecified", "awake", "asleepCore", "asleepDeep", "asleepREM"], from: 0)),
        ("AbdominalCramps", severity), ("Acne", severity),
        ("AppetiteChanges", values(["unspecified", "noChange", "decreased", "increased"], from: 0)),
        ("BladderIncontinence", severity), ("Bloating", severity), ("BreastPain", severity),
        ("ChestTightnessOrPain", severity), ("Chills", severity), ("Constipation", severity), ("Coughing", severity),
        ("Diarrhea", severity), ("Dizziness", severity), ("DrySkin", severity), ("Fainting", severity),
        ("Fatigue", severity), ("Fever", severity), ("GeneralizedBodyAche", severity), ("HairLoss", severity),
        ("Headache", severity), ("Heartburn", severity), ("HotFlashes", severity), ("LossOfSmell", severity),
        ("LossOfTaste", severity), ("LowerBackPain", severity), ("MemoryLapse", severity), ("MoodChanges", presence),
        ("Nausea", severity), ("NightSweats", severity), ("PelvicPain", severity),
        ("RapidPoundingOrFlutteringHeartbeat", severity), ("RunnyNose", severity), ("ShortnessOfBreath", severity),
        ("SinusCongestion", severity), ("SkippedHeartbeat", severity), ("SleepChanges", presence),
        ("SoreThroat", severity), ("VaginalDryness", severity), ("Vomiting", severity), ("Wheezing", severity),
    ]

    /// The lowerCamel Swift member name for an identifier suffix (`VO2Max` → `vo2Max`, `UVExposure` → `uvExposure`).
    static func friendlyName(_ suffix: String) -> String {
        let chars = Array(suffix)
        let run = chars.prefix { $0.isUppercase }.count
        guard run > 0 else { return suffix }
        let lower = run > 1 && run < chars.count && chars[run].isLowercase ? run - 1 : run
        return String(chars[..<lower]).lowercased() + String(chars[lower...])
    }

    /// Identifiers whose runtime string differs from the constant's name: Apple renamed the
    /// constant but kept the old string.
    static let runtimeCategoryIdentifiers = [
        "EnvironmentalAudioExposureEvent": "HKCategoryTypeIdentifierAudioExposureEvent",
    ]

    /// Every shareable type, in `types` order.
    public static let catalog: [Entry] = {
        var entries: [Entry] = []
        for (suffix, unit, aggregation) in quantitySpecs {
            entries.append(Entry(
                name: friendlyName(suffix), identifier: "HKQuantityTypeIdentifier" + suffix, kind: .quantity,
                unit: unit, aggregation: aggregation, values: nil))
        }
        for (suffix, values) in categorySpecs {
            entries.append(Entry(
                name: friendlyName(suffix), identifier: runtimeCategoryIdentifiers[suffix] ?? "HKCategoryTypeIdentifier" + suffix, kind: .category,
                unit: nil, aggregation: nil, values: values))
        }
        entries.append(Entry(
            name: "bloodPressure", identifier: "HKCorrelationTypeIdentifierBloodPressure", kind: .correlation,
            unit: "mmHg", aggregation: nil, values: nil))
        entries.append(Entry(
            name: "food", identifier: "HKCorrelationTypeIdentifierFood", kind: .correlation,
            unit: nil, aggregation: nil, values: nil))
        let others: [(String, String, Kind)] = [
            ("workout", "HKWorkoutTypeIdentifier", .workout),
            ("electrocardiogram", "HKDataTypeIdentifierElectrocardiogram", .electrocardiogram),
            ("audiogram", "HKDataTypeIdentifierAudiogram", .audiogram),
            ("stateOfMind", "HKDataTypeStateOfMind", .stateOfMind),
            ("gad7", "HKScoredAssessmentTypeIdentifierGAD7", .scoredAssessment),
            ("phq9", "HKScoredAssessmentTypeIdentifierPHQ9", .scoredAssessment),
            ("activitySummary", "HKActivitySummaryTypeIdentifier", .activitySummary),
        ]
        for (name, identifier, kind) in others {
            entries.append(Entry(name: name, identifier: identifier, kind: kind, unit: nil, aggregation: nil, values: nil))
        }
        return entries.sorted {
            $0.kind.rank != $1.kind.rank ? $0.kind.rank < $1.kind.rank : $0.name.lowercased() < $1.name.lowercased()
        }
    }()

    private static let lookup: [String: Entry] = {
        var map: [String: Entry] = [:]
        for entry in catalog {
            map[entry.name.lowercased()] = entry
            map[entry.identifier.lowercased()] = entry
        }
        // The documented spelling; the runtime identifier is `HKDataTypeStateOfMind`.
        map["hkdatatypeidentifierstateofmind"] = map["stateofmind"]
        map["hkcategorytypeidentifierenvironmentalaudioexposureevent"] = map["environmentalaudioexposureevent"]
        return map
    }()

    private static let neverSharedNames: Set<String> = [
        "clinicalrecords", "clinicalrecord", "documents", "document", "cda", "medications", "medication",
        "medicationdoseevent", "userannotatedmedication", "userannotatedmedicationconcept",
        "visionprescriptions", "visionprescription", "characteristics", "characteristic", "workoutroutes",
        "workoutroute", "heartbeatseries", "heartbeat", "audioexposureevent", "electrocardiogramvoltage",
        "allergyrecord", "clinicalnoterecord", "conditionrecord", "coveragerecord", "immunizationrecord",
        "labresultrecord", "medicationrecord", "procedurerecord", "vitalsignrecord",
        "activitymovemode", "biologicalsex", "bloodtype", "dateofbirth", "fitzpatrickskintype", "wheelchairuse",
        "hkworkoutroutetypeidentifier",
        "hkdatatypeidentifierheartbeatseries", "hkvisionprescriptiontypeidentifier", "hkdocumenttypeidentifiercda",
        "hkdatatypeidentifieruserannotatedmedicationconcept",
    ]
    private static let neverSharedPrefixes = [
        "hkclinicaltypeidentifier", "hkcharacteristictypeidentifier", "hkdocumenttypeidentifier", "hkmedication",
        "hkvisionprescription", "hkprescription",
    ]

    public enum Resolution: Equatable, Sendable {
        case entry(Entry)
        case neverShared
        case unknown
    }

    /// A friendly name (case-insensitive) or the full HealthKit identifier.
    public static func resolve(_ name: String) -> Resolution {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let entry = self.lookup[key] { return .entry(entry) }
        if self.neverSharedNames.contains(key) || self.neverSharedPrefixes.contains(where: { key.hasPrefix($0) }) {
            return .neverShared
        }
        return .unknown
    }

    public static func entry(identifier: String) -> Entry? {
        self.lookup[identifier.lowercased()]
    }

    // MARK: Params

    /// A validated request: everything the HealthKit runner needs.
    public struct Request: Sendable, Equatable {
        public var mode: Mode
        public var entry: Entry?
        public var range: DateInterval
        public var interval: Interval
        public var limit: Int
        public var sort: Sort
        /// Statistics buckets, anchored in the device calendar; empty for other modes.
        public var buckets: [DateInterval]
        public var timeZone: TimeZone
    }

    static func invalid(_ message: String) -> DeviceNodeFailure {
        DeviceNodeFailure(code: "INVALID_REQUEST", message: "INVALID_REQUEST: \(message)")
    }

    static func unavailable(_ message: String) -> DeviceNodeFailure {
        DeviceNodeFailure(code: "UNAVAILABLE", message: "HEALTH_UNAVAILABLE: \(message)")
    }

    public static let healthUnavailable = unavailable("Health data isn't available on this device")
    public static let timedOut = DeviceNodeFailure(
        code: "UNAVAILABLE", message: "HEALTH_TIMEOUT: the query took too long; shorten the range or use statistics")
    public static let cancelled = DeviceNodeFailure(code: "UNAVAILABLE", message: "UNAVAILABLE: request cancelled")
    public static let readFailed = unavailable("could not read Health data")
    public static let tooManyCategorySamples = unavailable("too much data for category statistics; shorten the range")

    public static func needsNewerOS(_ entry: Entry) -> DeviceNodeFailure {
        unavailable("\(entry.name) needs a newer iOS version")
    }

    public static func notDetermined(_ entry: Entry) -> DeviceNodeFailure {
        unavailable("Pincer hasn't asked for access to \(entry.name) yet; on the device, turn All Apple Health data off and on in Gateway Settings › This Device")
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Validates `paramsJSON` (missing = `{}`). Pure; runs before any HealthKit availability check.
    public static func request(_ paramsJSON: String?, now: Date, calendar: Calendar) -> Result<Request, DeviceNodeFailure> {
        let text = paramsJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let object: [String: Any]
        if text.isEmpty {
            object = [:]
        } else {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return .failure(self.invalid("params must be a JSON object"))
            }
            object = parsed.filter { !($0.value is NSNull) }
        }
        if let unknown = object.keys.sorted().first(where: { !self.allowedParams.contains($0) }) {
            return .failure(self.invalid(
                "unknown parameter \"\(unknown)\"; allowed: \(self.allowedParams.joined(separator: ", "))"))
        }

        var mode = Mode.samples
        if let value = object["mode"] {
            guard let string = value as? String, let parsed = Mode(rawValue: string) else {
                return .failure(self.invalid("mode must be types, samples or statistics"))
            }
            mode = parsed
        }
        if object["interval"] != nil, mode != .statistics {
            return .failure(self.invalid("interval only applies to statistics"))
        }
        for key in ["limit", "sort"] where object[key] != nil && mode != .samples {
            return .failure(self.invalid("\(key) only applies to samples"))
        }

        var interval = Interval.day
        if let value = object["interval"] {
            guard let string = value as? String, let parsed = Interval(rawValue: string) else {
                return .failure(self.invalid("interval must be hour, day, week, month or total"))
            }
            interval = parsed
        }
        var limit = self.defaultLimit
        if let value = object["limit"] {
            guard !self.isBool(value), let number = value as? NSNumber,
                  number.doubleValue == number.doubleValue.rounded(),
                  (1...Double(self.maxLimit)).contains(number.doubleValue)
            else { return .failure(self.invalid("limit must be an integer from 1 to \(self.maxLimit)")) }
            limit = number.intValue
        }
        var sort = Sort.desc
        if let value = object["sort"] {
            guard let string = value as? String, let parsed = Sort(rawValue: string) else {
                return .failure(self.invalid("sort must be desc or asc"))
            }
            sort = parsed
        }

        var entry: Entry?
        if mode != .types {
            guard let value = object["type"] else {
                return .failure(self.invalid("type is required; call with {\"mode\":\"types\"} to list types"))
            }
            let name = value as? String ?? "\(value)"
            switch self.resolve(name) {
            case let .entry(found): entry = found
            case .neverShared:
                return .failure(self.invalid(
                    "\(name) is never shared (clinical records, documents, medications, vision prescriptions, characteristics, workout routes and heartbeat series are excluded)"))
            case .unknown:
                return .failure(self.invalid("unknown type \"\(name)\"; call with {\"mode\":\"types\"} to list types"))
            }
        }

        var end = now
        if let value = object["endISO"] {
            guard let string = value as? String, let date = self.parseDate(string, isEnd: true, calendar: calendar) else {
                return .failure(self.invalid("endISO must be an ISO 8601 date or date-time"))
            }
            end = date
        }
        var start = calendar.date(byAdding: .day, value: -7, to: end) ?? end.addingTimeInterval(-7 * 86400)
        if let value = object["startISO"] {
            guard let string = value as? String, let date = self.parseDate(string, isEnd: false, calendar: calendar) else {
                return .failure(self.invalid("startISO must be an ISO 8601 date or date-time"))
            }
            start = date
        }
        guard start < end else { return .failure(self.invalid("startISO must be before endISO")) }
        // An hour of slack absorbs a daylight-saving change inside a full-length range.
        guard end.timeIntervalSince(start) <= Double(self.maxSpanDays) * 86400 + 3600 else {
            return .failure(self.invalid("the range can be at most \(self.maxSpanDays) days"))
        }
        let range = DateInterval(start: start, end: end)

        var buckets: [DateInterval] = []
        if mode == .statistics, let entry {
            guard entry.kind == .quantity || entry.kind == .category else {
                return .failure(self.invalid(
                    "statistics supports quantity and category types; use samples for \(entry.name)"))
            }
            buckets = self.buckets(range, interval, calendar: calendar)
            guard buckets.count <= self.maxBuckets else {
                return .failure(self.invalid(
                    "\(buckets.count) buckets is more than \(self.maxBuckets); use a larger interval or a shorter range"))
            }
        }
        return .success(Request(
            mode: mode, entry: entry, range: range, interval: interval, limit: limit, sort: sort, buckets: buckets,
            timeZone: calendar.timeZone))
    }

    /// ISO 8601 date-time (`Z` or an offset, optional fractional seconds) or a date-only `YYYY-MM-DD`:
    /// local midnight starting that day, or for an end, the next local midnight.
    public static func parseDate(_ string: String, isEnd: Bool, calendar: Calendar) -> Date? {
        let text = string.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        if text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        {
            guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
            else { return nil }
            let check = calendar.dateComponents([.year, .month, .day], from: date)
            guard check.year == year, check.month == month, check.day == day else { return nil }
            let midnight = calendar.startOfDay(for: date)
            return isEnd ? calendar.date(byAdding: .day, value: 1, to: midnight) : midnight
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Buckets anchored in `calendar` (hour on the hour, day at local midnight, week at the start of the
    /// locale's week, month on the 1st) that overlap `range`; `total` is the range itself.
    public static func buckets(_ range: DateInterval, _ interval: Interval, calendar: Calendar) -> [DateInterval] {
        let component: Calendar.Component
        switch interval {
        case .total: return [range]
        case .hour: component = .hour
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        var start = calendar.dateInterval(of: component, for: range.start)?.start ?? range.start
        var result: [DateInterval] = []
        while start < range.end, result.count <= 100_000 {
            guard let next = calendar.date(byAdding: component, value: 1, to: start), next > start else { break }
            result.append(DateInterval(start: start, end: next))
            start = next
        }
        return result
    }

    /// The anchor and step for HealthKit's statistics collection query.
    public static func intervalComponents(_ interval: Interval) -> DateComponents {
        switch interval {
        case .hour: DateComponents(hour: 1)
        case .day, .total: DateComponents(day: 1)
        case .week: DateComponents(weekOfYear: 1)
        case .month: DateComponents(month: 1)
        }
    }

    // MARK: Numbers and dates

    /// `|v| ≥ 1` → 2 decimals; `|v| < 1` → 4 significant digits, so micronutrients in grams survive.
    public static func round(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return 0 }
        if abs(value) >= 1 { return (value * 100).rounded() / 100 }
        let digits = 3 - Int(floor(log10(abs(value))))
        let scale = pow(10, Double(min(digits, 22)))
        return (value * scale).rounded() / scale
    }

    /// Seconds → minutes, 1 decimal.
    public static func minutes(_ seconds: TimeInterval) -> Double {
        (seconds / 60 * 10).rounded() / 10
    }

    /// ISO 8601 with the device's local offset. ISO8601DateFormatter is thread-safe; one per request.
    public final class Stamp: @unchecked Sendable {
        private let formatter = ISO8601DateFormatter()
        private let day = DateFormatter()

        public init(timeZone: TimeZone) {
            self.formatter.timeZone = timeZone
            self.formatter.formatOptions = [.withInternetDateTime]
            self.day.calendar = Calendar(identifier: .gregorian)
            self.day.locale = Locale(identifier: "en_US_POSIX")
            self.day.timeZone = timeZone
            self.day.dateFormat = "yyyy-MM-dd"
        }

        public func string(_ date: Date) -> String { self.formatter.string(from: date) }
        // periphery:ignore - used only by the iOS HealthKit runner (activity summaries)
        public func date(_ date: Date) -> String { self.day.string(from: date) }
    }

    // MARK: Category statistics

    public struct CategorySample: Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var value: Int

        public init(start: Date, end: Date, value: Int) {
            self.start = start
            self.end = end
            self.value = value
        }
    }

    /// Each sample lands in the bucket containing its **end** (a night belongs to the morning you
    /// wake). Per bucket: `count`, and minutes per value (or `minutes` for not-applicable types) with
    /// overlaps merged. Empty buckets are omitted.
    public static func categoryBuckets(
        _ samples: [CategorySample], entry: Entry, buckets: [DateInterval], stamp: Stamp) -> [Bucket]
    {
        let everything = DateInterval(start: .distantPast, end: .distantFuture)
        func minutes(_ group: [CategorySample]) -> Double {
            let merged = HealthSummary.mergedDuration(
                group.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }, clippedTo: everything)
            return self.minutes(merged ?? 0)
        }
        var result: [Bucket] = []
        var remaining = samples.sorted { $0.end < $1.end }[...]
        for bucket in buckets {
            while let first = remaining.first, first.end <= bucket.start { remaining.removeFirst() }
            var inBucket: [CategorySample] = []
            while let first = remaining.first, first.end <= bucket.end {
                inBucket.append(first)
                remaining.removeFirst()
            }
            guard !inBucket.isEmpty else { continue }
            var row = Bucket(start: stamp.string(bucket.start), end: stamp.string(bucket.end))
            row.count = inBucket.count
            if entry.values != nil {
                var byValue: [String: Double] = [:]
                for (raw, group) in Dictionary(grouping: inBucket, by: \.value) {
                    byValue[entry.valueName(raw) ?? "unknown(\(raw))"] = minutes(group)
                }
                row.minutesByValue = byValue
            } else {
                row.minutes = minutes(inBucket)
            }
            result.append(row)
        }
        return result
    }

    // MARK: Enum names

    public static func workoutActivityName(_ raw: UInt) -> String {
        self.workoutActivities[raw] ?? "other(\(raw))"
    }

    private static let workoutActivities: [UInt: String] = {
        let names = [
            "americanFootball", "archery", "australianFootball", "badminton", "baseball", "basketball", "bowling",
            "boxing", "climbing", "cricket", "crossTraining", "curling", "cycling", "dance", "danceInspiredTraining",
            "elliptical", "equestrianSports", "fencing", "fishing", "functionalStrengthTraining", "golf", "gymnastics",
            "handball", "hiking", "hockey", "hunting", "lacrosse", "martialArts", "mindAndBody",
            "mixedMetabolicCardioTraining", "paddleSports", "play", "preparationAndRecovery", "racquetball", "rowing",
            "rugby", "running", "sailing", "skatingSports", "snowSports", "soccer", "softball", "squash",
            "stairClimbing", "surfingSports", "swimming", "tableTennis", "tennis", "trackAndField",
            "traditionalStrengthTraining", "volleyball", "walking", "waterFitness", "waterPolo", "waterSports",
            "wrestling", "yoga", "barre", "coreTraining", "crossCountrySkiing", "downhillSkiing", "flexibility",
            "highIntensityIntervalTraining", "jumpRope", "kickboxing", "pilates", "snowboarding", "stairs",
            "stepTraining", "wheelchairWalkPace", "wheelchairRunPace", "taiChi", "mixedCardio", "handCycling",
            "discSports", "fitnessGaming", "cardioDance", "socialDance", "pickleball", "cooldown",
        ]
        var map: [UInt: String] = [:]
        for (offset, name) in names.enumerated() { map[UInt(offset + 1)] = name }
        map[82] = "swimBikeRun"
        map[83] = "transition"
        map[84] = "underwaterDiving"
        map[3000] = "other"
        return map
    }()

    public static func electrocardiogramClassification(_ raw: Int) -> String {
        let names = [
            "notSet", "sinusRhythm", "atrialFibrillation", "inconclusiveLowHeartRate", "inconclusiveHighHeartRate",
            "inconclusivePoorReading", "inconclusiveOther",
        ]
        if raw == 100 { return "unrecognized" }
        return names.indices.contains(raw) ? names[raw] : "unknown(\(raw))"
    }

    public static func electrocardiogramSymptoms(_ raw: Int) -> String {
        let names = ["notSet", "none", "present"]
        return names.indices.contains(raw) ? names[raw] : "unknown(\(raw))"
    }

    private static func named(_ names: [String], _ raw: Int, from first: Int = 1) -> String {
        names.indices.contains(raw - first) ? names[raw - first] : "unknown(\(raw))"
    }

    public static func stateOfMindKind(_ raw: Int) -> String {
        self.named(["momentaryEmotion", "dailyMood"], raw)
    }

    public static func valenceClassification(_ raw: Int) -> String {
        self.named([
            "veryUnpleasant", "unpleasant", "slightlyUnpleasant", "neutral", "slightlyPleasant", "pleasant",
            "veryPleasant",
        ], raw)
    }

    public static func stateOfMindLabel(_ raw: Int) -> String {
        self.named([
            "amazed", "amused", "angry", "anxious", "ashamed", "brave", "calm", "content", "disappointed",
            "discouraged", "disgusted", "embarrassed", "excited", "frustrated", "grateful", "guilty", "happy",
            "hopeless", "irritated", "jealous", "joyful", "lonely", "passionate", "peaceful", "proud", "relieved",
            "sad", "scared", "stressed", "surprised", "worried", "annoyed", "confident", "drained", "hopeful",
            "indifferent", "overwhelmed", "satisfied",
        ], raw)
    }

    public static func stateOfMindAssociation(_ raw: Int) -> String {
        self.named([
            "community", "currentEvents", "dating", "education", "family", "fitness", "friends", "health",
            "hobbies", "identity", "money", "partner", "selfCare", "spirituality", "tasks", "travel", "work",
            "weather",
        ], raw)
    }

    public static func gad7Risk(_ raw: Int) -> String {
        self.named(["noneToMinimal", "mild", "moderate", "severe"], raw)
    }

    public static func phq9Risk(_ raw: Int) -> String {
        self.named(["noneToMinimal", "mild", "moderate", "moderatelySevere", "severe"], raw)
    }

    // MARK: Payloads (optional fields are omitted, never null)

    public struct TypeInfo: Codable, Sendable, Equatable {
        public var name: String
        public var kind: String
        public var unit: String?
        public var aggregation: String?
        public var values: [String]?
    }

    public struct TypesPayload: Codable, Sendable, Equatable {
        public var mode = "types"
        public var usage: String
        public var types: [TypeInfo]
        public var excluded: [String]
    }

    /// The `types` answer: catalog entries that resolve on this OS (`isAvailable`), in catalog order.
    public static func typesPayload(isAvailable: (Entry) -> Bool = { _ in true }) -> TypesPayload {
        TypesPayload(
            usage: self.usage,
            types: self.catalog.filter(isAvailable).map {
                TypeInfo(
                    name: $0.name, kind: $0.kind.rawValue, unit: $0.unit, aggregation: $0.aggregation?.rawValue,
                    values: $0.values?.map(\.name))
            },
            excluded: self.excluded)
    }

    public struct QuantityRow: Codable, Sendable, Equatable {
        public var start: String
        public var end: String?
        public var value: Double
        public var source: String
        public var userEntered: Bool?

        public init(start: String, end: String? = nil, value: Double, source: String, userEntered: Bool? = nil) {
            self.start = start
            self.end = end
            self.value = value
            self.source = source
            self.userEntered = userEntered
        }
    }

    public struct CategoryRow: Codable, Sendable, Equatable {
        public var start: String
        public var end: String
        public var durationMinutes: Double
        public var value: Int?
        public var valueName: String?
        public var source: String
        public var userEntered: Bool?

        public init(
            start: String, end: String, durationMinutes: Double, value: Int? = nil, valueName: String? = nil,
            source: String, userEntered: Bool? = nil)
        {
            self.start = start
            self.end = end
            self.durationMinutes = durationMinutes
            self.value = value
            self.valueName = valueName
            self.source = source
            self.userEntered = userEntered
        }
    }

    // periphery:ignore - built only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public struct BloodPressureRow: Codable, Sendable, Equatable {
        public var start: String
        public var end: String?
        public var systolic: Double?
        public var diastolic: Double?
        public var source: String

        public init(start: String, end: String? = nil, systolic: Double?, diastolic: Double?, source: String) {
            self.start = start
            self.end = end
            self.systolic = systolic
            self.diastolic = diastolic
            self.source = source
        }
    }

    // periphery:ignore - built only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public struct Nutrient: Codable, Sendable, Equatable {
        public var type: String
        public var value: Double
        public var unit: String

        public init(type: String, value: Double, unit: String) {
            self.type = type
            self.value = value
            self.unit = unit
        }
    }

    // periphery:ignore - built only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public struct FoodRow: Codable, Sendable, Equatable {
        public var start: String
        public var end: String?
        public var foodName: String?
        public var nutrients: [Nutrient]
        public var source: String

        public init(start: String, end: String? = nil, foodName: String? = nil, nutrients: [Nutrient], source: String) {
            self.start = start
            self.end = end
            self.foodName = foodName
            self.nutrients = nutrients
            self.source = source
        }
    }

    public struct WorkoutRow: Codable, Sendable, Equatable {
        public var start: String
        public var end: String
        public var activityType: String
        public var durationMinutes: Double
        public var activeEnergyKcal: Double?
        public var distanceMeters: Double?
        public var averageHeartRateBpm: Double?
        public var maxHeartRateBpm: Double?
        public var source: String

        public init(
            start: String, end: String, activityType: String, durationMinutes: Double, activeEnergyKcal: Double? = nil,
            distanceMeters: Double? = nil, averageHeartRateBpm: Double? = nil, maxHeartRateBpm: Double? = nil,
            source: String)
        {
            self.start = start
            self.end = end
            self.activityType = activityType
            self.durationMinutes = durationMinutes
            self.activeEnergyKcal = activeEnergyKcal
            self.distanceMeters = distanceMeters
            self.averageHeartRateBpm = averageHeartRateBpm
            self.maxHeartRateBpm = maxHeartRateBpm
            self.source = source
        }
    }

    // periphery:ignore - built only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public struct ElectrocardiogramRow: Codable, Sendable, Equatable {
        public var start: String
        public var end: String
        public var classification: String
        public var averageHeartRateBpm: Double?
        public var symptomsStatus: String
        public var samplingFrequencyHz: Double?
        public var voltageMeasurementCount: Int
        public var source: String

        public init(
            start: String, end: String, classification: String, averageHeartRateBpm: Double? = nil,
            symptomsStatus: String, samplingFrequencyHz: Double? = nil, voltageMeasurementCount: Int, source: String)
        {
            self.start = start
            self.end = end
            self.classification = classification
            self.averageHeartRateBpm = averageHeartRateBpm
            self.symptomsStatus = symptomsStatus
            self.samplingFrequencyHz = samplingFrequencyHz
            self.voltageMeasurementCount = voltageMeasurementCount
            self.source = source
        }
    }

    // periphery:ignore - built only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public struct AudiogramPoint: Codable, Sendable, Equatable {
        public var frequencyHz: Double
        public var leftEarDBHL: Double?
        public var rightEarDBHL: Double?

        public init(frequencyHz: Double, leftEarDBHL: Double? = nil, rightEarDBHL: Double? = nil) {
            self.frequencyHz = frequencyHz
            self.leftEarDBHL = leftEarDBHL
            self.rightEarDBHL = rightEarDBHL
        }
    }

    // periphery:ignore - built only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public struct AudiogramRow: Codable, Sendable, Equatable {
        public var start: String
        public var points: [AudiogramPoint]
        public var source: String

        public init(start: String, points: [AudiogramPoint], source: String) {
            self.start = start
            self.points = points
            self.source = source
        }
    }

    // periphery:ignore - built only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public struct StateOfMindRow: Codable, Sendable, Equatable {
        public var start: String
        public var kind: String
        public var valence: Double
        public var valenceClassification: String
        public var labels: [String]
        public var associations: [String]
        public var source: String

        public init(
            start: String, kind: String, valence: Double, valenceClassification: String, labels: [String],
            associations: [String], source: String)
        {
            self.start = start
            self.kind = kind
            self.valence = valence
            self.valenceClassification = valenceClassification
            self.labels = labels
            self.associations = associations
            self.source = source
        }
    }

    // periphery:ignore - built only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public struct AssessmentRow: Codable, Sendable, Equatable {
        public var start: String
        public var score: Int
        public var risk: String
        public var source: String

        public init(start: String, score: Int, risk: String, source: String) {
            self.start = start
            self.score = score
            self.risk = risk
            self.source = source
        }
    }

    // periphery:ignore - built only by the iOS HealthKit runner (DeviceHealthAccess.swift)
    public struct ActivitySummaryRow: Codable, Sendable, Equatable {
        public var date: String
        public var activeEnergyKcal: Double?
        public var activeEnergyGoalKcal: Double?
        public var exerciseMinutes: Double?
        public var exerciseGoalMinutes: Double?
        public var standHours: Double?
        public var standGoalHours: Double?

        public init(
            date: String, activeEnergyKcal: Double? = nil, activeEnergyGoalKcal: Double? = nil,
            exerciseMinutes: Double? = nil, exerciseGoalMinutes: Double? = nil, standHours: Double? = nil,
            standGoalHours: Double? = nil)
        {
            self.date = date
            self.activeEnergyKcal = activeEnergyKcal
            self.activeEnergyGoalKcal = activeEnergyGoalKcal
            self.exerciseMinutes = exerciseMinutes
            self.exerciseGoalMinutes = exerciseGoalMinutes
            self.standHours = standHours
            self.standGoalHours = standGoalHours
        }
    }

    public struct SamplesPayload<Row: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        public var mode = "samples"
        public var type: String
        public var kind: String
        public var unit: String?
        public var startISO: String
        public var endISO: String
        public var timeZoneIdentifier: String
        public var sort: Sort
        public var limit: Int
        public var count: Int
        public var hasMore: Bool
        public var samples: [Row]
    }

    /// `rows` is what the runner fetched (up to `limit + 1`, already in `sort` order).
    public static func samplesPayload<Row: Codable & Sendable & Equatable>(_ request: Request, rows: [Row], stamp: Stamp) -> SamplesPayload<Row> {
        let page = Array(rows.prefix(request.limit))
        return SamplesPayload(
            type: request.entry?.name ?? "", kind: request.entry?.kind.rawValue ?? "",
            unit: request.entry?.unit,
            startISO: stamp.string(request.range.start), endISO: stamp.string(request.range.end),
            timeZoneIdentifier: request.timeZone.identifier, sort: request.sort, limit: request.limit,
            count: page.count, hasMore: rows.count > request.limit, samples: page)
    }

    public struct Bucket: Codable, Sendable, Equatable {
        public var start: String
        public var end: String
        public var sum: Double?
        public var average: Double?
        public var min: Double?
        public var max: Double?
        public var count: Int?
        public var minutes: Double?
        public var minutesByValue: [String: Double]?

        public init(
            start: String, end: String, sum: Double? = nil, average: Double? = nil, min: Double? = nil,
            max: Double? = nil, count: Int? = nil, minutes: Double? = nil, minutesByValue: [String: Double]? = nil)
        {
            self.start = start
            self.end = end
            self.sum = sum
            self.average = average
            self.min = min
            self.max = max
            self.count = count
            self.minutes = minutes
            self.minutesByValue = minutesByValue
        }

        var isEmpty: Bool {
            self.sum == nil && self.average == nil && self.min == nil && self.max == nil && self.count == nil
        }
    }

    public struct StatisticsPayload: Codable, Sendable, Equatable {
        public var mode = "statistics"
        public var type: String
        public var kind: String
        public var unit: String?
        public var aggregation: Aggregation?
        public var interval: Interval
        public var startISO: String
        public var endISO: String
        public var timeZoneIdentifier: String
        public var buckets: [Bucket]
    }

    public static func statisticsPayload(_ request: Request, buckets: [Bucket], stamp: Stamp) -> StatisticsPayload {
        StatisticsPayload(
            type: request.entry?.name ?? "", kind: request.entry?.kind.rawValue ?? "", unit: request.entry?.unit,
            aggregation: request.entry?.aggregation, interval: request.interval,
            startISO: stamp.string(request.range.start), endISO: stamp.string(request.range.end),
            timeZoneIdentifier: request.timeZone.identifier, buckets: buckets.filter { !$0.isEmpty })
    }

    /// The `node.invoke.result` reply for a payload.
    public static func result(_ payload: some Encodable) -> DeviceNodeResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload), let json = String(data: data, encoding: .utf8) else {
            return .failure(code: "UNAVAILABLE", message: "UNAVAILABLE: could not encode the result")
        }
        return .ok(payloadJSON: json)
    }

    /// How long the runner may take: the request's `timeoutMs` minus 500 ms, 14.5 s by default.
    public static func deadline(timeoutMs: Int?) -> TimeInterval {
        Double(max(500, (timeoutMs ?? self.defaultTimeoutMs) - 500)) / 1000
    }
}
