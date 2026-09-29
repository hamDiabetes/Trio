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

enum NightscoutProfileImportError: LocalizedError {
    case invalidCarbRatios
    case invalidBasalRates
    case zeroTotalBasal
    case invalidSensitivities
    case missingTargets
    case implausibleTargets(Decimal)
    case ambiguousUnits(String)
    case malformedBasalSchedule

    var errorDescription: String? {
        switch self {
        case .invalidCarbRatios:
            return String(localized: "Invalid Carb Ratio settings in Nightscout. Import aborted.")
        case .invalidBasalRates:
            return String(localized: "Invalid Nightscout basal rates found. Import aborted.")
        case .zeroTotalBasal:
            return String(
                localized: "Invalid Nightscout basal rates found. Basal rate total cannot be 0 U/hr. Import aborted."
            )
        case .invalidSensitivities:
            return String(localized: "Invalid Nightscout insulin sensitivity profile. Import aborted.")
        case .missingTargets:
            return String(localized: "The Nightscout profile has no glucose targets. Import aborted.")
        case let .implausibleTargets(value):
            return String(
                localized: "The Nightscout profile has a glucose target of \(value) mg/dL, which is outside the range Trio accepts. Import aborted."
            )
        case .malformedBasalSchedule:
            return String(
                localized: "The Nightscout profile's basal schedule does not start at midnight or has repeated times. Import aborted."
            )
        case let .ambiguousUnits(units):
            return String(
                localized: "The Nightscout profile is labelled \(units) but its values do not match those units. Import aborted."
            )
        }
    }
}

enum NightscoutProfileConverter {
    /// Targets Trio is prepared to accept from a profile, in mg/dL.
    ///
    /// Matches the bounds of Trio's own targets editor, since a target outside them cannot be
    /// represented once imported and would be silently coerced to the nearest one it can.
    /// It also catches the realistic way the unit guess below is defeated: a profile authored
    /// elsewhere can carry a placeholder target of 0, which reads as mmol/L and multiplies every
    /// sensitivity by 18.
    private static let plausibleTargetRange: ClosedRange<Decimal> = 72 ... 180

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

        let carbRatioEntries = profile.carbratio.map { entry in
            CarbRatioEntry(start: entry.time, offset: offset(entry.time) / 60, ratio: entry.value)
        }
        guard !carbRatioEntries.contains(where: { $0.ratio <= 0 }) else {
            throw NightscoutProfileImportError.invalidCarbRatios
        }

        // Sorted here because the pump's schedule type neither sorts nor validates: an entry missing
        // from midnight, or a repeated time, reaches a fatalError once the schedule is looked up.
        let basals = profile.basal
            .map { BasalProfileEntry(start: $0.time, minutes: offset($0.time) / 60, rate: $0.value) }
            .sorted { $0.minutes < $1.minutes }
        guard !basals.contains(where: { $0.rate <= 0 }) else {
            throw NightscoutProfileImportError.invalidBasalRates
        }
        let basalMinutes = basals.map(\.minutes)
        guard basalMinutes.first == 0, Set(basalMinutes).count == basalMinutes.count else {
            throw NightscoutProfileImportError.malformedBasalSchedule
        }
        guard basals.reduce(0, { $0 + $1.rate }) > 0 else {
            throw NightscoutProfileImportError.zeroTotalBasal
        }

        let sensitivityEntries = profile.sens.map { entry in
            InsulinSensitivityEntry(
                sensitivity: convert ? entry.value.asMgdL : entry.value,
                offset: offset(entry.time) / 60,
                start: entry.time
            )
        }
        guard !sensitivityEntries.contains(where: { $0.sensitivity <= 0 }) else {
            throw NightscoutProfileImportError.invalidSensitivities
        }

        let targetEntries = profile.target_low.map { entry in
            let value = convert ? entry.value.asMgdL : entry.value
            return BGTargetEntry(low: value, high: value, start: entry.time, offset: offset(entry.time) / 60)
        }
        guard !targetEntries.isEmpty else {
            throw NightscoutProfileImportError.missingTargets
        }
        if let outOfRange = targetEntries.first(where: { !plausibleTargetRange.contains($0.low) }) {
            throw NightscoutProfileImportError.implausibleTargets(outOfRange.low)
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
