import Combine
import Foundation
import LoopKit
import LoopKitUI
import SwiftUI
import Swinject

/// Why a profile cannot be applied right now.
///
/// Every case is a refusal to start rather than a failure part way through: once the pod has been
/// told to change its schedule there is no undo, so everything that can be checked is checked first.
enum ProfileSwitchBlock: LocalizedError, Equatable, Hashable {
    case noPump
    case pumpSuspended
    case bolusInProgress
    case looping
    case reducedTempBasalRunning
    case unsupportedBasalRate(Decimal)
    case pumpLimitOutOfRange(ProfilePumpLimit, Decimal)
    case basalAboveMaxBasal(rate: Decimal, maxBasal: Decimal)
    case unreadableSettings

    var errorDescription: String? {
        switch self {
        case .noPump:
            return String(localized: "No pump is connected. Connect a pump before switching profiles.")
        case .pumpSuspended:
            return String(localized: "Insulin delivery is suspended. Resume delivery before switching profiles.")
        case .bolusInProgress:
            return String(localized: "A bolus is in progress. Wait for it to finish before switching profiles.")
        case .looping:
            return String(localized: "Trio is running a loop right now. Try again in a moment.")
        case .reducedTempBasalRunning:
            return String(
                localized: "A reduced temporary basal is running, which usually means Trio is protecting against a low. Switching now would cancel it and resume full basal delivery. Wait for it to end."
            )
        case let .unsupportedBasalRate(rate):
            return String(localized: "This profile has a basal rate of \(rate) U/hr, which your pump cannot deliver.")
        case let .pumpLimitOutOfRange(limit, value):
            return String(
                localized: "This profile sets \(limit.label) to \(value) \(limit.unit), outside the \(limit.range.lowerBound)–\(limit.range.upperBound) \(limit.unit) Trio allows."
            )
        case .unreadableSettings:
            return String(
                localized: "Trio cannot read this profile's saved algorithm settings. Save the profile again before switching to it."
            )
        case let .basalAboveMaxBasal(rate, maxBasal):
            return String(
                localized: "This profile has a basal rate of \(rate) U/hr, above its maximum basal of \(maxBasal) U/hr."
            )
        }
    }
}

/// The three pump settings a profile carries, and the range each must fall in.
enum ProfilePumpLimit: String, Hashable, CaseIterable {
    case dia
    case maxBolus
    case maxBasal

    var label: String {
        switch self {
        case .dia: return String(localized: "Insulin Duration")
        case .maxBolus: return String(localized: "Max Bolus")
        case .maxBasal: return String(localized: "Max Basal")
        }
    }

    var unit: String {
        switch self {
        case .dia: return "h"
        case .maxBolus: return "U"
        case .maxBasal: return "U/hr"
        }
    }

    /// The ranges Trio's own settings screens allow, so a profile cannot install a value a person
    /// could not have entered by hand.
    var range: ClosedRange<Decimal> {
        let settings = PickerSettingsProvider.shared.settings
        switch self {
        case .dia: return settings.dia.min ... settings.dia.max
        case .maxBolus: return settings.maxBolus.min ... settings.maxBolus.max
        case .maxBasal: return settings.maxBasal.min ... settings.maxBasal.max
        }
    }

    func value(in settings: PumpSettings) -> Decimal {
        switch self {
        case .dia: return settings.insulinActionCurve
        case .maxBolus: return settings.maxBolus
        case .maxBasal: return settings.maxBasal
        }
    }
}

/// A switch that started but did not finish. It stays until a switch succeeds or someone confirms the
/// pump, because until then the pump and Trio may be running different settings.
struct ProfileSwitchMarker: JSON, Equatable {
    let profileName: String
    let startedAt: Date
    var pumpWriteConfirmed: Bool
    var settingsWritten: Bool
    var pumpAcceptedAfterTimeout: Bool? = nil
    /// Insulin duration, maximum bolus and maximum basal had already been changed.
    var pumpLimitsWritten: Bool? = nil
    var switchID: UUID? = UUID()
}

/// What preflight needs to know about the pump and the loop, gathered in one place so the rules can be
/// checked without a pump.
struct ProfileSwitchPreflight {
    var pumpPresent = true
    var suspended = false
    var bolusInProgress = false
    var looping = false
    var tempBasalRate: Decimal?
    /// Nil when the running schedule cannot be read.
    var scheduledRate: Decimal?
    var supportedBasalRates: [Decimal] = []
}

extension Profiles {
    final class SwitchService: Injectable {
        @Injected() private var apsManager: APSManager!
        @Injected() private var settingsManager: SettingsManager!
        @Injected() private var storage: FileStorage!
        @Injected() private var adjustmentManager: AdjustmentManager!
        @Injected() private var broadcaster: Broadcaster!
        @Injected() private var tidepoolManager: TidepoolManager!

        private let resolver: Resolver

        init(resolver: Resolver) {
            self.resolver = resolver
            injectServices(resolver)
        }

        var interruptedSwitch: ProfileSwitchMarker? {
            storage.retrieve(OpenAPS.Trio.profileSwitchMarker, as: ProfileSwitchMarker.self)
        }

        func clearInterruptedSwitch() {
            storage.remove(OpenAPS.Trio.profileSwitchMarker)
        }

        // MARK: - Preflight

        func blocks(for therapy: NightscoutTherapySettings, profileSettings: TrioProfileSettings?) async -> [ProfileSwitchBlock] {
            var blocks = Self.blocks(
                preflight: currentPreflight(),
                basals: therapy.basals,
                incoming: profileSettings?.pumpSettings,
                live: settingsManager.pumpSettings
            )
            if let profileSettings, (try? Self.overlay(profileSettings, onto: settingsManager.preferences)) == nil {
                blocks.append(.unreadableSettings)
            }
            return blocks
        }

        private func currentPreflight() -> ProfileSwitchPreflight {
            guard let pump = apsManager.pumpManager else {
                return ProfileSwitchPreflight(pumpPresent: false)
            }
            var preflight = ProfileSwitchPreflight(
                suspended: apsManager.isSuspended,
                bolusInProgress: apsManager.bolusProgress.value != nil,
                looping: apsManager.isLooping.value,
                supportedBasalRates: pump.supportedBasalRates.map { Decimal($0) }
            )
            if case let .tempBasal(dose) = pump.status.basalDeliveryState {
                preflight.tempBasalRate = Decimal(dose.unitsPerHour)
                let schedule = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
                preflight.scheduledRate = (try? Basal.basalLookup(schedule, now: Date())) ?? nil
            }
            return preflight
        }

        static func blocks(
            preflight: ProfileSwitchPreflight,
            basals: [BasalProfileEntry],
            incoming: PumpSettings?,
            live: PumpSettings
        ) -> [ProfileSwitchBlock] {
            var blocks = limitBlocks(basals: basals, incoming: incoming, live: live)
            guard preflight.pumpPresent else {
                return blocks + [.noPump]
            }
            if preflight.suspended { blocks.append(.pumpSuspended) }
            if preflight.bolusInProgress { blocks.append(.bolusInProgress) }
            if preflight.looping { blocks.append(.looping) }

            // A temp below the schedule is usually Trio holding back against a low. Writing a schedule
            // cancels it and nothing restores it until the next loop. When the schedule cannot be read,
            // any running temp is treated as one.
            if let temp = preflight.tempBasalRate, temp < (preflight.scheduledRate ?? .greatestFiniteMagnitude) {
                blocks.append(.reducedTempBasalRunning)
            }

            let supported = preflight.supportedBasalRates
            if !supported.isEmpty, let unsupported = basals.first(where: { !supported.contains($0.rate) }) {
                blocks.append(.unsupportedBasalRate(unsupported.rate))
            }
            return blocks
        }

        /// Values Trio's own settings screens would refuse, and basal rates above the maximum basal in
        /// force after the switch.
        static func limitBlocks(
            basals: [BasalProfileEntry],
            incoming: PumpSettings?,
            live: PumpSettings
        ) -> [ProfileSwitchBlock] {
            var blocks: [ProfileSwitchBlock] = []
            if let incoming {
                for limit in ProfilePumpLimit.allCases where !limit.range.contains(limit.value(in: incoming)) {
                    blocks.append(.pumpLimitOutOfRange(limit, limit.value(in: incoming)))
                }
            }
            let maxBasal = (incoming ?? live).maxBasal
            if let high = basals.first(where: { $0.rate > maxBasal }) {
                blocks.append(.basalAboveMaxBasal(rate: high.rate, maxBasal: maxBasal))
            }
            return blocks
        }

        // MARK: - Apply

        @MainActor func apply(
            name: String,
            therapy: NightscoutTherapySettings,
            profileSettings: TrioProfileSettings?
        ) async throws {
            // Checked again because the confirmation can sit open while delivery is suspended, a bolus
            // starts or a temp basal is set.
            if let block = await blocks(for: therapy, profileSettings: profileSettings).first {
                throw block
            }
            // Worked out before anything changes, so a profile whose settings no longer decode is refused
            // rather than failing after the pump write.
            let preferences: Preferences?
            do {
                preferences = try profileSettings.map { try Self.overlay($0, onto: settingsManager.preferences) }
            } catch {
                throw ProfileSwitchBlock.unreadableSettings
            }

            try await Self.holdingLoop(
                begin: { await self.apsManager.beginLoopExclusion() },
                end: { await self.apsManager.endLoopExclusion() }
            ) {
                try await self.applyWhileLoopIsHeld(
                    name: name,
                    therapy: therapy,
                    pumpSettings: profileSettings?.pumpSettings,
                    preferences: preferences
                )
            }

            // After the release, since this waits for it. It recalculates without enacting; the nudge
            // below asks for a loop the way the Home screen does, subject to the loop interval.
            do {
                try await apsManager.determineBasalSync()
            } catch {
                debug(.apsManager, "Recalculation after a profile switch failed: \(error)")
            }
            apsManager.markNextLoopUserInitiated()
            apsManager.heartbeat(date: Date())
        }

        /// Runs `work` with the loop held off, and releases on every path. There is no timeout on the
        /// hold, so `work` has to bound its own waits.
        static func holdingLoop(
            begin: () async -> Bool,
            end: () async -> Void,
            _ work: () async throws -> Void
        ) async throws {
            guard await begin() else {
                throw ProfileSwitchBlock.looping
            }
            do {
                try await work()
            } catch {
                await end()
                throw error
            }
            await end()
        }

        @MainActor private func applyWhileLoopIsHeld(
            name: String,
            therapy: NightscoutTherapySettings,
            pumpSettings: PumpSettings?,
            preferences: Preferences?
        ) async throws {
            var marker = ProfileSwitchMarker(
                profileName: name,
                startedAt: Date(),
                pumpWriteConfirmed: false,
                settingsWritten: false
            )
            storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)

            let previousLimits = settingsManager.pumpSettings
            let writeLimits: (() async throws -> Void)? = pumpSettings.map { limits in
                {
                    // Recorded before the attempt: a write that fails can still have stored something.
                    marker.pumpLimitsWritten = true
                    self.storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)
                    let sent = marker
                    try await self.writePumpSettings(limits, onLateSuccess: { self.recordLateLimitWrite(for: sent) })
                }
            }

            try await Self.runSteps(
                writeLimits: writeLimits,
                restoreLimits: {
                    do {
                        try await self.writePumpSettings(previousLimits)
                        marker.pumpLimitsWritten = false
                        self.storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)
                    } catch {
                        debug(.service, "Could not restore the dosing limits after a failed profile switch: \(error)")
                    }
                },
                writeBasal: {
                    try await self.writeBasalSchedule(therapy.basals, marker: marker)
                    marker.pumpWriteConfirmed = true
                    self.storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)
                },
                endAdjustments: { try await self.disableActiveAdjustments() },
                writeSettings: {
                    try self.writeTherapySettings(therapy)
                    marker.settingsWritten = true
                    self.storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)
                    self.announceTherapySettings(therapy)

                    if let preferences {
                        try self.applyPreferences(preferences)
                    }
                }
            )

            // Autosens was derived against the settings just replaced and is otherwise reused for 30 min.
            storage.remove(OpenAPS.Settings.autosense)

            clearInterruptedSwitch()
        }

        /// Applies a switch's parts in order. Dosing limits go first, so pumps that check basal rates
        /// against the maximum basal accept the new schedule. Overrides and temp targets end only once the
        /// pump has the new schedule, since one is often protecting against a low. If any part fails after
        /// the limits may have changed, the previous limits are put back: a switch that fails at the pump
        /// must not leave a higher maximum bolus or a different insulin duration in force.
        static func runSteps(
            writeLimits: (() async throws -> Void)?,
            restoreLimits: () async -> Void,
            writeBasal: () async throws -> Void,
            endAdjustments: () async throws -> Void,
            writeSettings: () async throws -> Void
        ) async throws {
            do {
                try await writeLimits?()
                try await writeBasal()
                try await endAdjustments()
                try await writeSettings()
            } catch {
                if writeLimits != nil {
                    await restoreLimits()
                }
                throw error
            }
        }

        /// Ends any running override and temp target. Through the adjustment manager, because ending a
        /// temp target in Core Data alone leaves it in the file oref reads.
        private func disableActiveAdjustments() async throws {
            do {
                try await adjustmentManager.cancelOverride(source: .app, waitForUpload: false)
            } catch AdjustmentError.nothingActive {}

            do {
                try await adjustmentManager.cancelTempTarget(source: .app, waitForUpload: false)
            } catch AdjustmentError.nothingActive {}
        }

        // MARK: - Pump

        /// Long enough for a slow pod and its retries. Past this the outcome is unknown.
        static let pumpWriteTimeout: TimeInterval = 120

        /// Never skipped because the stored schedule already matches: the pod's schedule cannot be read
        /// back, and the stored copy diverges whenever a write goes unacknowledged.
        private func writeBasalSchedule(_ basals: [BasalProfileEntry], marker: ProfileSwitchMarker) async throws {
            guard let pump = apsManager.pumpManager else {
                throw ProfileSwitchBlock.noPump
            }
            let items = basals.map {
                RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate))
            }
            // Setting a schedule can fail before cancelling anything, and resuming then would restart
            // delivery someone suspended on purpose.
            let wasSuspendedBefore = isDeliverySuspended(pump)

            try await Self.boundedPumpWrite(
                timeout: Self.pumpWriteTimeout,
                send: { reply in
                    pump.syncBasalRateSchedule(items: items) { reply($0.map { _ in () }) }
                },
                recoverAfterFailure: {
                    if !wasSuspendedBefore, self.isDeliverySuspended(pump) {
                        await self.resumeDelivery(pump)
                    }
                },
                onLateSuccess: { self.recordLatePumpAcceptance(for: marker) }
            )
        }

        /// Sends one pump command and waits for its reply, but not past `timeout`.
        ///
        /// The outcome is settled before any recovery runs, so a slow recovery cannot turn a failure into
        /// a timeout. A failure in time is recovered from before this returns, while the caller still
        /// holds the loop; a late one is recovered from when it arrives. A late success is handed to
        /// `onLateSuccess`: the pump took the command after Trio stopped waiting.
        static func boundedPumpWrite(
            timeout: TimeInterval,
            send: (@escaping (Result<Void, Error>) -> Void) -> Void,
            recoverAfterFailure: @escaping () async -> Void,
            onLateSuccess: @escaping () async -> Void
        ) async throws {
            let outcome = PumpWriteOutcome()
            send { result in
                Task {
                    guard await outcome.finish(result) == .late else { return }
                    switch result {
                    case .failure: await recoverAfterFailure()
                    case .success: await onLateSuccess()
                    }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await outcome.expire()
            }

            switch await outcome.wait() {
            case .success: return
            case let .failure(error):
                await recoverAfterFailure()
                throw error
            case nil: throw ProfileSwitchError.pumpWriteTimedOut
            }
        }

        /// Updates the marker of the switch that sent the command, or recreates it if someone has cleared
        /// it since. If another switch has started, its marker is left alone and the late reply is only
        /// logged: that switch writes the whole schedule again.
        private func recordLatePumpAcceptance(for sent: ProfileSwitchMarker) {
            debug(.service, "Pump accepted the \(sent.profileName) basal schedule after the switch stopped waiting")
            var marker = interruptedSwitch ?? sent
            guard sent.switchID != nil, marker.switchID == sent.switchID else { return }
            marker.pumpWriteConfirmed = true
            marker.pumpAcceptedAfterTimeout = true
            storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)
        }

        /// The profile's dosing limits reached the pump after the switch stopped waiting, possibly after
        /// the previous ones were put back.
        private func recordLateLimitWrite(for sent: ProfileSwitchMarker) {
            debug(.service, "Pump took the \(sent.profileName) dosing limits after the switch stopped waiting")
            var marker = interruptedSwitch ?? sent
            guard sent.switchID != nil, marker.switchID == sent.switchID else { return }
            marker.pumpLimitsWritten = true
            storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)
        }

        private func isDeliverySuspended(_ pump: PumpManagerUI) -> Bool {
            switch pump.status.basalDeliveryState {
            case .suspended,
                 .suspending: return true
            default: return false
            }
        }

        private func resumeDelivery(_ pump: PumpManagerUI) async {
            do {
                try await Self.boundedPumpWrite(
                    timeout: Self.pumpWriteTimeout,
                    send: { reply in
                        pump.resumeDelivery { error in reply(error.map { .failure($0) } ?? .success(())) }
                    },
                    recoverAfterFailure: {},
                    onLateSuccess: {}
                )
            } catch {
                debug(.apsManager, "Could not resume delivery after a failed basal write: \(error)")
            }
        }

        /// Saves through the settings screen's own path, which syncs the limits to the pump and stores
        /// what the pump reports back.
        private func writePumpSettings(
            _ pumpSettings: PumpSettings,
            onLateSuccess: @escaping () async -> Void = {}
        ) async throws {
            let provider = UnitsLimitsSettings.Provider(resolver: resolver)
            var subscription: AnyCancellable?
            try await Self.savePumpSettings(
                pumpSettings,
                save: {
                    try await Self.boundedPumpWrite(
                        timeout: Self.pumpWriteTimeout,
                        send: { reply in
                            // The provider's Future always sends a value or fails, so finishing without one
                            // cannot happen; if it ever did, the deadline would report it.
                            subscription = provider.save(settings: pumpSettings).sink(
                                receiveCompletion: { if case let .failure(error) = $0 { reply(.failure(error)) } },
                                receiveValue: { reply(.success(())) }
                            )
                        },
                        recoverAfterFailure: {},
                        onLateSuccess: onLateSuccess
                    )
                    subscription?.cancel()
                },
                stored: { self.storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self) }
            )
        }

        /// Saves the limits and reads them back. The provider stores what the pump reports, which can
        /// differ from what was asked for, and a switch must not claim limits the pump did not take.
        static func savePumpSettings(
            _ pumpSettings: PumpSettings,
            save: () async throws -> Void,
            stored: () -> PumpSettings?
        ) async throws {
            try await save()
            guard stored() == pumpSettings else {
                throw ProfileSwitchError.pumpSettingsNotWritten
            }
        }

        // MARK: - Settings

        private func writeTherapySettings(_ therapy: NightscoutTherapySettings) throws {
            storage.transaction { storage in
                storage.save(therapy.basals, as: OpenAPS.Settings.basalProfile)
                storage.save(therapy.carbRatios, as: OpenAPS.Settings.carbRatios)
                storage.save(therapy.sensitivities, as: OpenAPS.Settings.insulinSensitivities)
                storage.save(therapy.targets, as: OpenAPS.Settings.bgTargets)
            }

            // FileStorage.save swallows its errors, so the files are read back. Times are compared as well
            // as values.
            let basals = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
            let ratios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
            let sensitivities = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
            let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)

            guard basals?.map({ [$0.minutes: $0.rate] }) == therapy.basals.map({ [$0.minutes: $0.rate] }),
                  ratios?.schedule.map({ [$0.offset: $0.ratio] })
                  == therapy.carbRatios.schedule.map({ [$0.offset: $0.ratio] }),
                  sensitivities?.sensitivities.map({ [$0.offset: $0.sensitivity] })
                  == therapy.sensitivities.sensitivities.map({ [$0.offset: $0.sensitivity] }),
                  targets?.targets.map({ [$0.offset: $0.low] }) == therapy.targets.targets.map({ [$0.offset: $0.low] })
            else {
                throw ProfileSwitchError.settingsNotWritten
            }
        }

        /// What each therapy editor does after saving, so Home, the watch and Tidepool see the change.
        private func announceTherapySettings(_ therapy: NightscoutTherapySettings) {
            broadcaster.notify(BasalProfileObserver.self, on: .main) { $0.basalProfileDidChange(therapy.basals) }
            broadcaster.notify(CarbRatiosObserver.self, on: .main) { $0.carbRatiosDidChange(therapy.carbRatios) }
            broadcaster.notify(InsulinSensitivitiesObserver.self, on: .main) {
                $0.insulinSensitivitiesDidChange(therapy.sensitivities)
            }
            broadcaster.notify(BGTargetsObserver.self, on: .main) { $0.bgTargetsDidChange(therapy.targets) }
            Task { await tidepoolManager.uploadSettings() }
        }

        private func applyPreferences(_ preferences: Preferences) throws {
            settingsManager.preferences = preferences
            guard storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self) == preferences else {
                throw ProfileSwitchError.preferencesNotWritten
            }
        }

        /// Overlays a profile's algorithm settings onto the live ones key by key. Decoding the profile's
        /// payload on its own would reset every missing field to its default, and `maxIOB`'s is zero.
        static func overlay(_ profileSettings: TrioProfileSettings, onto live: Preferences) throws -> Preferences {
            var merged = try JSONValue(encoding: live).objectValue ?? [:]
            for (key, value) in profileSettings.preferences {
                merged[key] = value
            }
            let mergedData = try JSONCoding.encoder.encode(JSONValue.object(merged))
            return try JSONCoding.decoder.decode(Preferences.self, from: mergedData)
        }
    }
}

enum ProfileSwitchError: LocalizedError, CaseIterable {
    case settingsNotWritten
    case preferencesNotWritten
    case pumpWriteTimedOut
    case pumpSettingsNotWritten

    var errorDescription: String? {
        switch self {
        case .settingsNotWritten:
            return String(
                localized: "Your pump has the new basal rates but Trio could not save the new therapy settings. Check your therapy settings before dosing."
            )
        case .pumpSettingsNotWritten:
            return String(
                localized: "Trio could not confirm the profile's insulin duration, maximum bolus and maximum basal. Check them before dosing."
            )
        case .pumpWriteTimedOut:
            return String(
                localized: "Your pump did not confirm the new basal rates in time and may still take them. Check your pump's basal rates before dosing, or switch again."
            )
        case .preferencesNotWritten:
            return String(
                localized: "Trio applied the new therapy settings but could not save the profile's algorithm settings. Check your algorithm settings before dosing."
            )
        }
    }
}

/// The reply to one pump command, or its absence by a deadline. Whichever comes first settles it.
actor PumpWriteOutcome {
    enum Arrival { case inTime, late, duplicate }

    private var result: Result<Void, Error>?
    private var expired = false
    private var waiter: CheckedContinuation<Result<Void, Error>?, Never>?

    @discardableResult func finish(_ result: Result<Void, Error>) -> Arrival {
        if self.result != nil { return .duplicate }
        if expired {
            self.result = result
            return .late
        }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
        return .inTime
    }

    func expire() {
        guard result == nil, !expired else { return }
        expired = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    /// The reply, or nil if the deadline passed first.
    func wait() async -> Result<Void, Error>? {
        if expired { return nil }
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}
