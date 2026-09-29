import Foundation

struct FetchedNightscoutProfileStore: JSON {
    let _id: String
    let defaultProfile: String
    let startDate: String
    let mills: Decimal
    let enteredBy: String
    let store: [String: ScheduledNightscoutProfile]
    let created_at: String
}

struct FetchedNightscoutProfile: JSON {
    let dia: Decimal
    let carbs_hr: Int
    let delay: Decimal
    let timezone: String
    let target_low: [NightscoutTimevalue]
    let target_high: [NightscoutTimevalue]
    let sens: [NightscoutTimevalue]
    let basal: [NightscoutTimevalue]
    let carbratio: [NightscoutTimevalue]
    let units: String
}

/// The named profiles in a Nightscout profile document.
struct NightscoutProfileStoreContents {
    let profiles: [String: ScheduledNightscoutProfile]
    /// Profiles present in the document that Trio could not read, named so they are not silently absent.
    let unreadable: [String]
}

/// Trio's four therapy schedules, as read out of one Nightscout profile.
struct NightscoutTherapySettings {
    let targets: BGTargets
    let basals: [BasalProfileEntry]
    let carbRatios: CarbRatios
    let sensitivities: InsulinSensitivities
    /// The `units` string the profile carried, kept for the caller to decide the display unit.
    let units: String
}

enum NightscoutProfileImportError: LocalizedError, Equatable {
    case carbRatioOutOfRange(Decimal)
    case invalidBasalRates
    case sensitivityOutOfRange(Decimal)
    case missingTargets
    case implausibleTargets(Decimal)
    case ambiguousUnits(String)
    case malformedSchedule

    var errorDescription: String? {
        switch self {
        case let .carbRatioOutOfRange(value):
            return String(
                localized: "The Nightscout profile has a carb ratio of \(value) g/U, which is outside the range Trio accepts. Import aborted."
            )
        case .invalidBasalRates:
            return String(localized: "Invalid Nightscout basal rates found. Import aborted.")
        case let .sensitivityOutOfRange(value):
            return String(
                localized: "The Nightscout profile has an insulin sensitivity of \(value) mg/dL/U, which is outside the range Trio accepts. Import aborted."
            )
        case .missingTargets:
            return String(localized: "The Nightscout profile has no glucose targets. Import aborted.")
        case let .implausibleTargets(value):
            return String(
                localized: "The Nightscout profile has a glucose target of \(value) mg/dL, which is outside the range Trio accepts. Import aborted."
            )
        case .malformedSchedule:
            return String(
                localized: "A schedule in the Nightscout profile does not start at midnight or has repeated times. Import aborted."
            )
        case let .ambiguousUnits(units):
            return String(
                localized: "The Nightscout profile is labelled \(units) but its values do not match those units. Import aborted."
            )
        }
    }
}

enum NightscoutProfileConverter {
    /// The ranges Trio's own editors allow, in mg/dL and g/U. A value outside them cannot be entered by
    /// hand, and a zero target is also how the unit guess below is defeated: it reads as mmol/L and
    /// multiplies every sensitivity by 18.
    private static var sensitivityRange: ClosedRange<Decimal> { range(\.insulinSensitivity) }
    private static var targetRange: ClosedRange<Decimal> { range(\.glucoseTarget) }
    private static var carbRatioRange: ClosedRange<Decimal> { range(\.carbRatio) }

    private static func range(_ setting: KeyPath<DecimalPickerSettings, PickerSetting>) -> ClosedRange<Decimal> {
        let picker = PickerSettingsProvider.shared.settings[keyPath: setting]
        return picker.min ... picker.max
    }

    /// Whether a profile's values need converting from mmol/L.
    ///
    /// Nightscout profiles carry a `units` string, but it is frequently wrong, so the values are used
    /// as the tiebreak: a target expressed in mmol/L is always well under the lowest plausible mg/dL
    /// target.
    static func shouldConvertToMgdL(_ profile: ScheduledNightscoutProfile) -> Bool {
        profile.units.contains("mmol") || profile.target_low.contains(where: { $0.value <= 39 })
            || profile.target_high.contains(where: { $0.value <= 39 })
    }

    /// Reads one Nightscout profile into Trio's therapy settings.
    ///
    /// Throws rather than substituting a default for anything it cannot read: every value here is a
    /// dosing input, so a profile that is partly understood is worse than one that is rejected.
    static func therapySettings(from profile: ScheduledNightscoutProfile) throws -> NightscoutTherapySettings {
        let convert = shouldConvertToMgdL(profile)

        // A profile whose label and values disagree cannot be read safely in either direction.
        if profile.units.contains("mmol"), profile.target_low.contains(where: { $0.value > 39 }) {
            throw NightscoutProfileImportError.ambiguousUnits(profile.units)
        }

        let carbRatioEntries = try schedule(profile.carbratio) { time, minutes, value in
            CarbRatioEntry(start: time, offset: minutes, ratio: value)
        }
        if let bad = carbRatioEntries.first(where: { !carbRatioRange.contains($0.ratio) }) {
            throw NightscoutProfileImportError.carbRatioOutOfRange(bad.ratio)
        }

        // The pump's schedule type neither sorts nor validates, and an entry missing from midnight or a
        // repeated time reaches a fatalError once the schedule is looked up.
        let basals = try schedule(profile.basal) { time, minutes, value in
            BasalProfileEntry(start: time, minutes: minutes, rate: value)
        }
        guard !basals.contains(where: { $0.rate <= 0 }) else {
            throw NightscoutProfileImportError.invalidBasalRates
        }

        let sensitivityEntries = try schedule(profile.sens) { time, minutes, value in
            InsulinSensitivityEntry(sensitivity: convert ? value.asMgdL : value, offset: minutes, start: time)
        }
        if let bad = sensitivityEntries.first(where: { !sensitivityRange.contains($0.sensitivity) }) {
            throw NightscoutProfileImportError.sensitivityOutOfRange(bad.sensitivity)
        }

        guard !profile.target_low.isEmpty else {
            throw NightscoutProfileImportError.missingTargets
        }
        let targetEntries = try schedule(profile.target_low) { time, minutes, value in
            let target = convert ? value.asMgdL : value
            return BGTargetEntry(low: target, high: target, start: time, offset: minutes)
        }
        if let bad = targetEntries.first(where: { !targetRange.contains($0.low) }) {
            throw NightscoutProfileImportError.implausibleTargets(bad.low)
        }

        return NightscoutTherapySettings(
            targets: BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: targetEntries),
            basals: basals,
            carbRatios: CarbRatios(units: .grams, schedule: carbRatioEntries),
            sensitivities: InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: sensitivityEntries
            ),
            units: profile.units
        )
    }

    /// Builds a schedule in time order, refusing one that does not start at midnight or repeats a time.
    private static func schedule<Entry>(
        _ values: [NightscoutTimevalue],
        _ make: (String, Int, Decimal) -> Entry
    ) throws -> [Entry] {
        let sorted = values
            .map { (value: $0, minutes: offset($0.time) / 60) }
            .sorted { $0.minutes < $1.minutes }
        let minutes = sorted.map(\.minutes)
        guard minutes.first == 0, Set(minutes).count == minutes.count else {
            throw NightscoutProfileImportError.malformedSchedule
        }
        return sorted.map { make($0.value.time, $0.minutes, $0.value.value) }
    }

    /// Whether a profile carries a target range rather than a single target.
    ///
    /// Trio has one target per time block and reads `target_low`, so a range would silently import as
    /// its lower bound. Callers surface this rather than applying it unannounced.
    static func hasTargetRange(_ profile: ScheduledNightscoutProfile) -> Bool {
        guard profile.target_low.count == profile.target_high.count else { return true }
        return zip(profile.target_low, profile.target_high).contains { $0.value != $1.value }
    }

    /// Builds a Nightscout profile from Trio's therapy settings.
    ///
    /// The inverse of `therapySettings(from:)`, used to save the live settings as a named profile.
    /// Glucose values are written in the user's display units, matching what Trio already publishes
    /// for its own profile entry.
    static func nightscoutProfile(
        from therapy: NightscoutTherapySettings,
        units: GlucoseUnits,
        dia: Decimal,
        carbsPerHour: Int,
        timezone: String = TimeZone.current.identifier
    ) -> ScheduledNightscoutProfile {
        let mmol = units == .mmolL
        func timevalue(_ start: String, _ offsetMinutes: Int, _ value: Decimal) -> NightscoutTimevalue {
            NightscoutTimevalue(time: String(start.prefix(5)), value: value, timeAsSeconds: offsetMinutes * 60)
        }

        let targets = therapy.targets.targets.map {
            timevalue($0.start, $0.offset, mmol ? $0.low.asMmolL : $0.low)
        }

        return ScheduledNightscoutProfile(
            dia: dia,
            carbs_hr: carbsPerHour,
            delay: 0,
            timezone: timezone,
            target_low: targets,
            target_high: targets,
            sens: therapy.sensitivities.sensitivities.map {
                timevalue($0.start, $0.offset, mmol ? $0.sensitivity.asMmolL : $0.sensitivity)
            },
            basal: therapy.basals.map { timevalue($0.start, $0.minutes, $0.rate) },
            carbratio: therapy.carbRatios.schedule.map { timevalue($0.start, $0.offset, $0.ratio) },
            units: mmol ? "mmol" : "mg/dl"
        )
    }

    /// Seconds from midnight for a Nightscout `HH:MM` time.
    ///
    /// Split rather than sliced: profiles written by other apps carry "6:30" and "06:30:00", and
    /// reading fixed-width prefixes turns both into the wrong hour.
    static func offset(_ string: String) -> Int {
        let parts = string.split(separator: ":")
        let hours = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
        let minutes = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return ((hours * 60) + minutes) * 60
    }
}
