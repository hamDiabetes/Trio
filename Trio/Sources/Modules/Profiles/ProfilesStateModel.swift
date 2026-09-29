import Observation
import SwiftUI

extension Profiles {
    @Observable final class StateModel: BaseStateModel<Provider> {
        /// The name Trio publishes its live settings under. It is not offered as something to switch to.
        static let liveProfileName = "default"

        var loadState: LoadState = .idle
        var items: [Item] = []
        var applied: AppliedProfile?
        /// True when the live settings no longer match what the applied profile installed.
        var appliedProfileEdited = false
        /// Settings kept for profile names Nightscout no longer has.
        var unmatchedSettings: [String] = []
        /// Profiles Nightscout returned that Trio could not read, named so they are not silently absent.
        var unreadableProfiles: [String] = []

        var pendingSwitch: Item?
        var pendingBlocks: [ProfileSwitchBlock] = []
        var switchInProgress = false
        /// A switch that did not finish. Kept until a switch succeeds or a person says they have checked
        /// the pump, because the pump and Trio may be running different basal rates until then.
        var interrupted: ProfileSwitchMarker?
        /// Shows the interrupted switch as an alert once, right after it happens.
        var showInterruptedAlert = false
        var dosingMode: DosingMode = .closed
        var showSaveSheet = false
        var newProfileName = ""
        var errorMessage: String?

        private var switchServiceStorage: Profiles.SwitchService?

        private var switchService: Profiles.SwitchService {
            if let switchServiceStorage { return switchServiceStorage }
            let service = Profiles.SwitchService(resolver: resolver!)
            switchServiceStorage = service
            return service
        }

        override func subscribe() {
            Task { await load() }
        }

        /// What a switch to the pending profile would change, for the confirmation screen.
        var pendingChanges: ProfileSwitchPreview?

        /// Reads a profile and works out whether it can be applied, without changing anything.
        @MainActor func prepareSwitch(to item: Item) async {
            pendingSwitch = nil
            pendingBlocks = []
            do {
                let therapy = try NightscoutProfileConverter.therapySettings(from: item.profile)
                pendingBlocks = await switchService.blocks(for: therapy, pumpSettings: item.trioSettings?.pumpSettings)
                pendingChanges = ProfileSwitchPreview(
                    incoming: therapy,
                    current: await provider.currentTherapySettings(),
                    currentPreferences: provider.currentPreferences(),
                    currentPumpSettings: provider.currentPumpSettings(),
                    profileSettings: item.trioSettings,
                    hasTargetRange: NightscoutProfileConverter.hasTargetRange(item.profile),
                    convertedFromMmol: NightscoutProfileConverter.shouldConvertToMgdL(item.profile),
                    units: provider.displayUnits()
                )
                pendingSwitch = item
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        @MainActor func confirmSwitch() async {
            guard let item = pendingSwitch, pendingBlocks.isEmpty, !switchInProgress else { return }
            switchInProgress = true
            defer { switchInProgress = false }

            do {
                let therapy = try NightscoutProfileConverter.therapySettings(from: item.profile)
                try await switchService.apply(
                    name: item.name,
                    therapy: therapy,
                    profileSettings: item.trioSettings
                )

                // Taken from the settings as stored, the same source the edited check reads later. The
                // profile as converted from Nightscout encodes differently from the files it was written
                // to, which made every switch look edited straight away.
                if let applied = await provider.currentTherapySettings() {
                    let fingerprint = provider.fingerprint(
                        therapy: applied,
                        preferences: provider.currentPreferences(),
                        pumpSettings: provider.currentPumpSettings()
                    )
                    provider.saveAppliedProfile(
                        AppliedProfile(name: item.name, appliedAt: Date(), fingerprint: fingerprint)
                    )
                }

                // The switch itself has already happened. Nightscout not hearing about it is a gap in
                // the record, not a reason to tell the user the switch failed.
                do {
                    try await provider.uploadProfileSwitch(name: item.name, profile: item.profile)
                    // Trio's own entry still describes the settings that were running before, so
                    // anything reading the current document would report the wrong ones.
                    try await provider.publishLiveSettings()
                } catch {
                    debug(.nightscout, "Profile switch applied but not fully recorded in Nightscout: \(error)")
                }

                pendingSwitch = nil
                await load()
            } catch {
                // The sheet has to close before the message can be shown: SwiftUI will not present an
                // alert on a view a sheet is covering.
                pendingSwitch = nil
                interrupted = switchService.interruptedSwitch
                if interrupted == nil {
                    errorMessage = error.localizedDescription
                } else {
                    showInterruptedAlert = true
                }
                await load()
            }
        }

        @MainActor func dismissInterrupted() {
            switchService.clearInterruptedSwitch()
            interrupted = nil
        }

        @MainActor func load() async {
            loadState = .loading
            dosingMode = provider.dosingMode()
            applied = provider.appliedProfile()
            interrupted = switchService.interruptedSwitch

            let stored = provider.storedSettings()
            do {
                let contents = try await provider.fetchProfileStore()
                let store = contents.profiles
                unreadableProfiles = contents.unreadable
                items = store
                    .filter { $0.key != Self.liveProfileName }
                    .map { Item(name: $0.key, profile: $0.value, trioSettings: stored[$0.key]) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                // Settings kept for a profile the site no longer has: surfaced rather than deleted,
                // since a rename in the Nightscout editor looks exactly like a delete from here.
                unmatchedSettings = stored.keys
                    .filter { name in
                        name != Self.liveProfileName && !store.keys.contains(name) && !contents.unreadable.contains(name)
                    }
                    .sorted()

                await refreshAppliedState()
                loadState = .loaded
            } catch {
                loadState = .failed(error.localizedDescription)
            }
        }

        @MainActor private func refreshAppliedState() async {
            guard let applied, let therapy = await provider.currentTherapySettings() else {
                appliedProfileEdited = false
                return
            }
            let current = provider.fingerprint(
                therapy: therapy,
                preferences: provider.currentPreferences(),
                pumpSettings: provider.currentPumpSettings()
            )
            appliedProfileEdited = current != applied.fingerprint
        }

        var canSaveNewProfile: Bool {
            let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != Self.liveProfileName
        }

        var newProfileNameIsTaken: Bool {
            let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            return items.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        }

        @MainActor func saveCurrentSettings(as name: String) async {
            var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // The sheet offers "Replace" for a name that differs only in case, so replace that profile
            // rather than adding a second one beside it.
            if let existing = items.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                trimmed = existing.name
            }
            guard !trimmed.isEmpty, trimmed != Self.liveProfileName else { return }

            guard let therapy = await provider.currentTherapySettings() else {
                errorMessage = String(localized: "Could not read the current therapy settings.")
                return
            }

            do {
                let settings = try TrioProfileSettings(
                    from: provider.currentPreferences(),
                    pumpSettings: provider.currentPumpSettings()
                )
                try await provider.saveProfile(
                    named: trimmed,
                    profile: provider.nightscoutProfile(from: therapy),
                    settings: settings
                )
                newProfileName = ""
                showSaveSheet = false
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        @MainActor func delete(_ item: Item) async {
            do {
                try await provider.deleteProfile(named: item.name)
                if applied?.name == item.name {
                    provider.saveAppliedProfile(nil)
                    applied = nil
                }
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
