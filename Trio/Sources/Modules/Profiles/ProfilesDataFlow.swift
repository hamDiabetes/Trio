import Combine
import Foundation

enum Profiles {
    enum Config {}

    /// One named profile as the Profiles screen sees it.
    struct Item: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let profile: ScheduledNightscoutProfile
        /// Trio's own settings for this profile. Absent for a profile authored outside Trio.
        let trioSettings: TrioProfileSettings?

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.name == rhs.name && lhs.trioSettings == rhs.trioSettings
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }
}

/// The settings a profile carries that Nightscout has no representation for.
///
/// Stored on the device rather than in the Nightscout profile document: Nightscout's own profile
/// editor deletes any key it does not recognise from a store entry, and there is only ever one phone
/// running Trio, so nothing is gained by publishing them.
struct TrioProfileSettings: JSON, Equatable {
    /// Every field of `Preferences`, encoded key by key.
    ///
    /// Held as JSON rather than as `Preferences` so it can be overlaid onto the live preferences a key
    /// at a time. Decoding a `Preferences` from a partial payload silently resets every absent field
    /// to its default, which for `maxIOB` means zero.
    var preferences: [String: JSONValue]
    /// Insulin duration, maximum bolus and maximum basal. Absent in profiles saved before these were
    /// carried, in which case a switch leaves them as they are.
    var pumpSettings: PumpSettings?

    init(preferences: [String: JSONValue], pumpSettings: PumpSettings? = nil) {
        self.preferences = preferences
        self.pumpSettings = pumpSettings
    }

    init(from preferences: Preferences, pumpSettings: PumpSettings?) throws {
        self.preferences = try JSONValue(encoding: preferences).objectValue ?? [:]
        self.pumpSettings = pumpSettings
    }
}

/// What Trio last applied, so the Profiles screen can tell "running Tianna" from "running something
/// that started as Tianna".
struct AppliedProfile: JSON, Equatable {
    let name: String
    let appliedAt: Date
    /// Fingerprint of the therapy settings, preferences and dosing limits as applied.
    let fingerprint: String
}

protocol ProfilesProvider: Provider {
    func fetchProfileStore() async throws -> NightscoutProfileStoreContents
    func storedSettings() -> [String: TrioProfileSettings]
    func saveStoredSettings(_ settings: [String: TrioProfileSettings])
    func appliedProfile() -> AppliedProfile?
    func saveAppliedProfile(_ applied: AppliedProfile?)
    func currentTherapySettings() async -> NightscoutTherapySettings?
    func currentPreferences() -> Preferences
    func currentPumpSettings() -> PumpSettings
    func saveProfile(named name: String, profile: ScheduledNightscoutProfile, settings: TrioProfileSettings) async throws
    func deleteProfile(named name: String) async throws
    func fingerprint(therapy: NightscoutTherapySettings, preferences: Preferences, pumpSettings: PumpSettings) -> String
    func nightscoutProfile(from therapy: NightscoutTherapySettings) -> ScheduledNightscoutProfile
    func uploadProfileSwitch(name: String, profile: ScheduledNightscoutProfile) async throws
    func publishLiveSettings() async throws
    func displayUnits() -> GlucoseUnits
    func dosingMode() -> DosingMode
}
