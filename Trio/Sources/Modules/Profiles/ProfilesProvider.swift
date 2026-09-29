import CryptoKit
import Foundation

extension Profiles {
    final class Provider: BaseProvider, ProfilesProvider {
        @Injected() private var nightscout: NightscoutManager!
        @Injected() private var settingsManager: SettingsManager!

        func fetchProfileStore() async throws -> NightscoutProfileStoreContents {
            try await nightscout.fetchProfileStore()
        }

        func storedSettings() -> [String: TrioProfileSettings] {
            storage.retrieve(OpenAPS.Trio.profileSettings, as: [String: TrioProfileSettings].self) ?? [:]
        }

        func saveStoredSettings(_ settings: [String: TrioProfileSettings]) {
            storage.save(settings, as: OpenAPS.Trio.profileSettings)
        }

        func appliedProfile() -> AppliedProfile? {
            storage.retrieve(OpenAPS.Trio.appliedProfile, as: AppliedProfile.self)
        }

        func saveAppliedProfile(_ applied: AppliedProfile?) {
            guard let applied else {
                storage.remove(OpenAPS.Trio.appliedProfile)
                return
            }
            storage.save(applied, as: OpenAPS.Trio.appliedProfile)
        }

        func currentTherapySettings() async -> NightscoutTherapySettings? {
            async let sensitivities = storage.retrieveAsync(
                OpenAPS.Settings.insulinSensitivities,
                as: InsulinSensitivities.self
            )
            async let targets = storage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
            async let carbRatios = storage.retrieveAsync(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
            async let basals = storage.retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)

            guard let sensitivities = await sensitivities,
                  let targets = await targets,
                  let carbRatios = await carbRatios,
                  let basals = await basals
            else {
                return nil
            }

            return NightscoutTherapySettings(
                targets: targets,
                basals: basals,
                carbRatios: carbRatios,
                sensitivities: sensitivities,
                units: settingsManager.settings.units == .mmolL ? "mmol" : "mg/dl"
            )
        }

        func currentPreferences() -> Preferences {
            settingsManager.preferences
        }

        func currentPumpSettings() -> PumpSettings {
            settingsManager.pumpSettings
        }

        func saveProfile(
            named name: String,
            profile: ScheduledNightscoutProfile,
            settings: TrioProfileSettings
        ) async throws {
            // Nightscout first: if it refuses, the device must not be left claiming a profile the site
            // does not have.
            try await nightscout.saveNamedProfile(name, profile: profile)
            var stored = storedSettings()
            stored[name] = settings
            saveStoredSettings(stored)
        }

        func deleteProfile(named name: String) async throws {
            try await nightscout.deleteNamedProfile(name)
            var stored = storedSettings()
            stored.removeValue(forKey: name)
            saveStoredSettings(stored)
        }

        func nightscoutProfile(from therapy: NightscoutTherapySettings) -> ScheduledNightscoutProfile {
            let preferences = settingsManager.preferences
            let sensitivity = therapy.sensitivities.sensitivities.first?.sensitivity ?? 0
            let ratio = therapy.carbRatios.schedule.first?.ratio ?? 0
            var carbsPerHour: Decimal = 0
            if sensitivity > 0, ratio > 0 {
                carbsPerHour = preferences.min5mCarbimpact * 12 / sensitivity * ratio
            }

            // Saved in mg/dL whatever the display unit: mmol/L at one decimal does not survive the trip back.
            return NightscoutProfileConverter.nightscoutProfile(
                from: therapy,
                units: .mgdL,
                dia: settingsManager.pumpSettings.insulinActionCurve,
                carbsPerHour: Int(carbsPerHour)
            )
        }

        func uploadProfileSwitch(name: String, profile: ScheduledNightscoutProfile) async throws {
            try await nightscout.uploadProfileSwitch(name: name, profile: profile)
        }

        func displayUnits() -> GlucoseUnits {
            settingsManager.settings.units
        }

        func dosingMode() -> DosingMode {
            settingsManager.settings.dosingMode
        }

        func publishLiveSettings() async throws {
            try await nightscout.uploadProfiles()
        }

        func fingerprint(therapy: NightscoutTherapySettings, preferences: Preferences, pumpSettings: PumpSettings) -> String {
            Self.fingerprint(therapy: therapy, preferences: preferences, pumpSettings: pumpSettings)
        }

        /// A digest of everything a switch applies, stored so the screen can tell a profile that is still
        /// running from one edited since.
        static func fingerprint(
            therapy: NightscoutTherapySettings,
            preferences: Preferences,
            pumpSettings: PumpSettings
        ) -> String {
            var hasher = SHA256()
            for data in [
                try? canonicalJSON(therapy.targets),
                try? canonicalJSON(therapy.basals),
                try? canonicalJSON(therapy.carbRatios),
                try? canonicalJSON(therapy.sensitivities),
                try? canonicalJSON(preferences),
                try? canonicalJSON(pumpSettings)
            ] {
                hasher.update(data: data ?? Data())
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        /// Keys sorted, because the encoder's key order changes between launches and the fingerprint is
        /// compared across them.
        static func canonicalJSON(_ value: some Encodable) throws -> Data {
            let encoder = JSONCoding.encoder
            encoder.outputFormatting.insert(.sortedKeys)
            return try encoder.encode(value)
        }
    }
}
