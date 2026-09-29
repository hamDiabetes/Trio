import Foundation

/// What applying a profile would change, worked out before anything is applied.
///
/// Exists so the confirmation screen can state the change rather than describe it: the numbers a
/// switch installs are dosing inputs, and several of them are quietly adjusted on the way in.
struct ProfileSwitchPreview {
    struct Change: Identifiable {
        let id = UUID()
        let label: String
        let from: String
        let to: String
    }

    let therapyChanges: [Change]
    /// Insulin duration, maximum bolus and maximum basal, each listed only when it changes.
    let pumpChanges: [Change]
    /// False when the profile predates carrying pump settings, so they stay as they are.
    let carriesPumpSettings: Bool
    let preferenceChanges: [Change]
    /// True when the profile brings no algorithm settings, so only the therapy schedules change.
    let therapyOnly: Bool
    /// True when the profile carries a target range, which Trio stores as its lower bound alone.
    let hasTargetRange: Bool
    /// True when the profile's values were read as mmol/L and converted to mg/dL.
    let convertedFromMmol: Bool

    init(
        incoming: NightscoutTherapySettings,
        current: NightscoutTherapySettings?,
        currentPreferences: Preferences,
        currentPumpSettings: PumpSettings,
        profileSettings: TrioProfileSettings?,
        hasTargetRange: Bool,
        convertedFromMmol: Bool = false,
        units: GlucoseUnits = .mgdL
    ) {
        // Glucose values are held in mg/dL throughout Trio. A confirmation screen exists to be read,
        // so it has to show them the way the rest of the app does.
        func glucose(_ value: Decimal) -> String {
            units == .mmolL ? "\(value.asMmolL) mmol/L" : "\(value) mg/dL"
        }
        self.hasTargetRange = hasTargetRange
        self.convertedFromMmol = convertedFromMmol
        therapyOnly = profileSettings == nil

        var therapy: [Change] = []
        func compare(_ label: String, _ old: [String]?, _ new: [String]) {
            let oldText = old?.joined(separator: ", ") ?? "—"
            let newText = new.joined(separator: ", ")
            if oldText != newText {
                therapy.append(Change(label: label, from: oldText, to: newText))
            }
        }

        compare(
            String(localized: "Basal Rates"),
            current?.basals.map { "\($0.start.prefix(5)) \($0.rate) U/hr" },
            incoming.basals.map { "\($0.start.prefix(5)) \($0.rate) U/hr" }
        )
        compare(
            String(localized: "Carb Ratios"),
            current?.carbRatios.schedule.map { "\($0.start.prefix(5)) \($0.ratio) g/U" },
            incoming.carbRatios.schedule.map { "\($0.start.prefix(5)) \($0.ratio) g/U" }
        )
        compare(
            String(localized: "Insulin Sensitivities"),
            current?.sensitivities.sensitivities.map { "\($0.start.prefix(5)) \(glucose($0.sensitivity))" },
            incoming.sensitivities.sensitivities.map { "\($0.start.prefix(5)) \(glucose($0.sensitivity))" }
        )
        compare(
            String(localized: "Glucose Targets"),
            current?.targets.targets.map { "\($0.start.prefix(5)) \(glucose($0.low))" },
            incoming.targets.targets.map { "\($0.start.prefix(5)) \(glucose($0.low))" }
        )
        therapyChanges = therapy

        carriesPumpSettings = profileSettings?.pumpSettings != nil
        if let incomingPump = profileSettings?.pumpSettings {
            pumpChanges = ProfilePumpLimit.allCases.compactMap { limit in
                let from = limit.value(in: currentPumpSettings)
                let to = limit.value(in: incomingPump)
                guard from != to else { return nil }
                return Change(label: limit.label, from: "\(from) \(limit.unit)", to: "\(to) \(limit.unit)")
            }
        } else {
            pumpChanges = []
        }

        guard let profileSettings else {
            preferenceChanges = []
            return
        }

        // Compared key by key against the live values, so the screen lists only what actually moves.
        let currentJSON = (try? JSONCoding.encoder.encode(currentPreferences))
            .flatMap { try? JSONCoding.decoder.decode(JSONValue.self, from: $0) }?
            .objectValue ?? [:]

        preferenceChanges = profileSettings.preferences
            .filter { key, value in currentJSON[key] != value }
            .map { key, value in
                Change(
                    label: ProfileSwitchPreview.readableName(for: key),
                    from: ProfileSwitchPreview.describe(currentJSON[key]),
                    to: ProfileSwitchPreview.describe(value)
                )
            }
            .sorted { $0.label < $1.label }
    }

    /// Turns a preference key into something readable.
    ///
    /// `Preferences` carries oref's own key names, which are a mix: about thirty are snake_case
    /// (`max_iob`), the rest are camelCase (`enableUAM`), and a few are both (`enableSMB_high_bg`).
    /// Both shapes have to split for the confirmation screen to read like English.
    static func readableName(for key: String) -> String {
        let acronyms: Set<String> = ["iob", "cob", "smb", "uam", "isf", "bg", "tdd", "dia", "a52", "cgm"]

        var words: [String] = []
        for chunk in key.split(separator: "_") {
            var word = ""
            for (index, character) in chunk.enumerated() {
                let previous = index > 0 ? Array(chunk)[index - 1] : nil
                let next = index + 1 < chunk.count ? Array(chunk)[index + 1] : nil
                let startsWord = character.isUppercase
                    && (previous?.isLowercase == true || (previous?.isUppercase == true && next?.isLowercase == true))
                if startsWord, !word.isEmpty {
                    words.append(word)
                    word = ""
                }
                word.append(character)
            }
            if !word.isEmpty { words.append(word) }
        }

        return words
            .map { acronyms.contains($0.lowercased()) ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func describe(_ value: JSONValue?) -> String {
        switch value {
        case let .bool(flag): return flag ? "On" : "Off"
        case let .number(number): return "\(number)"
        case let .string(text): return text
        case .none,
             .some(.null): return "—"
        default: return "…"
        }
    }
}
