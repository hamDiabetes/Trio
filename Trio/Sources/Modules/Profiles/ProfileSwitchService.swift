import CoreData
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

/// A switch that started but whose outcome is unknown.
///
/// Written before the pump is touched and cleared only once everything downstream has succeeded. If it
/// survives, the pod and the algorithm may disagree and a person has to be told.
struct ProfileSwitchMarker: JSON, Equatable {
    let profileName: String
    let startedAt: Date
    /// False until the pump has acknowledged the new schedule.
    var pumpWriteConfirmed: Bool
    /// False until all four therapy files have been written and read back.
    var settingsWritten: Bool
    /// The pump accepted the new schedule after the switch had stopped waiting, so the pump runs the
    /// new basal rates while Trio kept the old settings.
    var pumpAcceptedAfterTimeout: Bool? = nil
    /// Identifies the switch, so a late reply updates the marker of the switch that sent it.
    var switchID: UUID? = UUID()
}

extension Profiles {
    /// Applies a profile: the one operation here that changes what the pump delivers.
    final class SwitchService: Injectable {
        @Injected() private var apsManager: APSManager!
        @Injected() private var settingsManager: SettingsManager!
        @Injected() private var storage: FileStorage!
        @Injected() private var nightscout: NightscoutManager!
        @Injected() private var adjustmentManager: AdjustmentManager!

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

        /// Everything that would stop a switch, checked before anything changes.
        func blocks(for therapy: NightscoutTherapySettings, pumpSettings: PumpSettings?) async -> [ProfileSwitchBlock] {
            var blocks = Self.limitBlocks(
                basals: therapy.basals,
                incoming: pumpSettings,
                live: settingsManager.pumpSettings
            )

            guard let pump = apsManager.pumpManager else {
                blocks.append(.noPump)
                return blocks
            }

            if apsManager.isSuspended {
                blocks.append(.pumpSuspended)
            }
            if apsManager.bolusProgress.value != nil {
                blocks.append(.bolusInProgress)
            }
            if apsManager.isLooping.value {
                blocks.append(.looping)
            }
            if isReducedTempBasalRunning() {
                blocks.append(.reducedTempBasalRunning)
            }

            let supported = pump.supportedBasalRates.map { Decimal($0) }
            if !supported.isEmpty, let unsupported = therapy.basals.first(where: { !supported.contains($0.rate) }) {
                blocks.append(.unsupportedBasalRate(unsupported.rate))
            }

            return blocks
        }

        /// Values a profile would install that Trio's own screens would refuse, and basal rates above
        /// the maximum basal that would be in force after the switch.
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

        /// A temp basal below the scheduled rate is usually Trio holding back against a falling glucose.
        /// Changing the schedule cancels it and resumes full delivery, and nothing puts it back until the
        /// next reading.
        ///
        /// Read from the pump's own delivery state rather than from storage: Trio keeps enacted temp
        /// basals in Core Data, and the file this once read is not written by anything.
        private func isReducedTempBasalRunning() -> Bool {
            guard case let .tempBasal(dose)? = apsManager.pumpManager?.status.basalDeliveryState else {
                return false
            }
            let profile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
            let now = Date()
            let minutesNow = Calendar.current.component(.hour, from: now) * 60
                + Calendar.current.component(.minute, from: now)
            return Decimal(dose.unitsPerHour) < Self.scheduledRate(in: profile, atMinute: minutesNow)
        }

        /// The scheduled basal rate at a time of day, given as minutes from local midnight, which is
        /// how offsets in a basal profile are expressed.
        static func scheduledRate(in profile: [BasalProfileEntry], atMinute minute: Int) -> Decimal {
            guard !profile.isEmpty else { return 0 }
            return profile.last(where: { $0.minutes <= minute })?.rate ?? profile[0].rate
        }

        // MARK: - Apply

        /// Applies a profile, in the order that leaves the least dangerous state at every step.
        ///
        /// Reversible work happens first, the single irreversible step is next, and everything after it
        /// is local. A failure anywhere leaves the marker behind so the screen can say what is unknown.
        @MainActor func apply(
            name: String,
            therapy: NightscoutTherapySettings,
            profileSettings: TrioProfileSettings?
        ) async throws {
            // The confirmation sheet can sit open indefinitely, and delivery can be suspended, a bolus
            // started or a loop begun in the meantime. None of those are visible to the checks made
            // when it was opened.
            let blocks = await blocks(for: therapy, pumpSettings: profileSettings?.pumpSettings)
            if let block = blocks.first {
                throw block
            }

            // Checked above as well, but only this claim is atomic: a scheduled loop can start between
            // any check and the first write, and would then read half old and half new settings.
            guard await apsManager.beginLoopExclusion() else {
                throw ProfileSwitchBlock.looping
            }
            do {
                try await applyWhileLoopIsHeld(name: name, therapy: therapy, profileSettings: profileSettings)
            } catch {
                await apsManager.endLoopExclusion()
                throw error
            }
            await apsManager.endLoopExclusion()

            // Recalculated against the new profile so the screens show it. Released first, since this
            // waits for the hold.
            do {
                try await apsManager.determineBasalSync()
            } catch {
                debug(.apsManager, "Recalculation after a profile switch failed: \(error)")
            }

            // Asks for a loop the way the Home screen's loop button does, so the new settings are enacted
            // through the normal loop and its guards. The loop interval still applies: if a loop started
            // under three minutes ago this is skipped, and the pump runs the new schedule until the next
            // reading.
            apsManager.markNextLoopUserInitiated()
            apsManager.heartbeat(date: Date())
        }

        @MainActor private func applyWhileLoopIsHeld(
            name: String,
            therapy: NightscoutTherapySettings,
            profileSettings: TrioProfileSettings?
        ) async throws {
            var marker = ProfileSwitchMarker(
                profileName: name,
                startedAt: Date(),
                pumpWriteConfirmed: false,
                settingsWritten: false
            )
            storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)

            // 1. Cancel what is layered on top of the profile, before the profile changes underneath it.
            //    Both are reversible and cancelling is the conservative direction.
            try await disableActiveAdjustments()

            // 2. Insulin duration and delivery limits, before the schedule: a raised maximum basal has to
            //    be in place before rates that need it are sent.
            if let pumpSettings = profileSettings?.pumpSettings {
                try await writePumpSettings(pumpSettings)
            }

            // 3. The pump. The only step that cannot be undone, and the only one that can leave delivery
            //    suspended if it fails part way through.
            try await writeBasalSchedule(therapy.basals, switchID: marker.switchID)
            marker.pumpWriteConfirmed = true
            storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)

            // 4. Therapy files, then read back: FileStorage.save swallows its errors, so a write that
            //    failed would otherwise be indistinguishable from one that worked.
            try writeTherapySettings(therapy)
            marker.settingsWritten = true
            storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)

            // 5. Algorithm settings, overlaid key by key onto the live ones.
            if let profileSettings {
                try applyPreferences(profileSettings)
            }

            // 6. Autosens was derived from deviations against the settings that have just been replaced,
            //    and is otherwise reused for up to 30 minutes.
            storage.remove(OpenAPS.Settings.autosense)

            clearInterruptedSwitch()
        }

        /// Ends any running override and temp target.
        ///
        /// A switch replaces the settings an override is scaling, so leaving one running would apply an
        /// old adjustment to new numbers. Routed through the adjustment manager because ending a temp
        /// target in Core Data alone leaves it in the file oref reads, where it keeps applying.
        private func disableActiveAdjustments() async throws {
            do {
                try await adjustmentManager.cancelOverride(source: .app, waitForUpload: false)
            } catch AdjustmentError.nothingActive {}

            do {
                try await adjustmentManager.cancelTempTarget(source: .app, waitForUpload: false)
            } catch AdjustmentError.nothingActive {}
        }

        /// Writes the basal schedule to the pump.
        ///
        /// Never skipped on the grounds that the stored schedule already matches: there is no way to read
        /// the pod's schedule back, and the stored copy diverges from it whenever a write goes
        /// unacknowledged or onboarding writes the file with no pump attached.
        private func writeBasalSchedule(_ basals: [BasalProfileEntry], switchID: UUID?) async throws {
            guard let pump = apsManager.pumpManager else {
                throw ProfileSwitchBlock.noPump
            }

            let items = basals.map {
                RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate))
            }

            // Only a failure that happened after delivery was cancelled should be resumed from. Setting
            // a schedule returns early — before cancelling anything — when there is no pod, when setup
            // is incomplete, when a bolus is unfinished and when comms cannot be validated. Resuming in
            // those cases would restart delivery that was deliberately suspended.
            let wasSuspendedBefore = isDeliverySuspended(pump)

            try await Self.boundedPumpWrite(
                timeout: Self.pumpWriteTimeout,
                send: { reply in
                    pump.syncBasalRateSchedule(items: items) { reply($0.map { _ in () }) }
                },
                recoverAfterFailure: {
                    if !wasSuspendedBefore, self.isDeliverySuspended(pump) {
                        await self.resumeDeliveryAfterFailedWrite(pump)
                    }
                },
                onLateSuccess: { self.recordLatePumpAcceptance(switchID: switchID) }
            )
        }

        /// Sends one pump command and waits for its reply, but not past `timeout`, because the loop is
        /// held off until this returns.
        ///
        /// A reply after the deadline is still acted on. A late failure still runs the recovery, since
        /// delivery may have been left suspended. A late success means the pump has the new schedule
        /// while Trio kept the old one, which cannot be repaired from here — the loop is running again —
        /// so it is recorded for a person to see instead.
        static func boundedPumpWrite(
            timeout: TimeInterval,
            send: (@escaping (Result<Void, Error>) -> Void) -> Void,
            recoverAfterFailure: @escaping () async -> Void,
            onLateSuccess: @escaping () async -> Void
        ) async throws {
            let outcome = PumpWriteOutcome()
            send { result in
                Task {
                    if case .failure = result {
                        await recoverAfterFailure()
                    }
                    let inTime = await outcome.finish(result)
                    if !inTime, case .success = result {
                        await onLateSuccess()
                    }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await outcome.expire()
            }

            switch await outcome.wait() {
            case .success: return
            case let .failure(error): throw error
            case nil: throw ProfileSwitchError.pumpWriteTimedOut
            }
        }

        /// Only the switch that sent the command is updated: by the time a late reply arrives a person may
        /// already have started another.
        private func recordLatePumpAcceptance(switchID: UUID?) {
            guard var marker = interruptedSwitch, switchID != nil, marker.switchID == switchID else { return }
            marker.pumpWriteConfirmed = true
            marker.pumpAcceptedAfterTimeout = true
            storage.save(marker, as: OpenAPS.Trio.profileSwitchMarker)
            debug(.service, "Pump accepted the \(marker.profileName) basal schedule after the switch gave up waiting")
        }

        /// Long enough for a slow pod and its retries. Past this the write's outcome is unknown.
        static let pumpWriteTimeout: TimeInterval = 120

        private func isDeliverySuspended(_ pump: PumpManagerUI) -> Bool {
            if case .suspended = pump.status.basalDeliveryState {
                return true
            }
            return false
        }

        private func resumeDeliveryAfterFailedWrite(_ pump: PumpManagerUI) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pump.resumeDelivery { error in
                    if let error {
                        debug(.apsManager, "Could not resume delivery after a failed basal write: \(error)")
                    }
                    continuation.resume()
                }
            }
        }

        /// Saves through the same path as the settings screen, which syncs the limits to the pump and
        /// stores what the pump reports back. Some pumps keep their own limits, so the stored values are
        /// compared with what was asked for.
        private func writePumpSettings(_ pumpSettings: PumpSettings) async throws {
            let provider = UnitsLimitsSettings.Provider(resolver: resolver)
            for try await _ in provider.save(settings: pumpSettings).values {}

            guard storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self) == pumpSettings else {
                throw ProfileSwitchError.pumpSettingsNotWritten
            }
        }

        private func writeTherapySettings(_ therapy: NightscoutTherapySettings) throws {
            storage.transaction { storage in
                storage.save(therapy.basals, as: OpenAPS.Settings.basalProfile)
                storage.save(therapy.carbRatios, as: OpenAPS.Settings.carbRatios)
                storage.save(therapy.sensitivities, as: OpenAPS.Settings.insulinSensitivities)
                storage.save(therapy.targets, as: OpenAPS.Settings.bgTargets)
            }

            let written = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
            let ratios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
            let sensitivities = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
            let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)

            // Times are compared as well as values: a schedule persisted with the right rates at the
            // wrong times would otherwise pass as confirmed.
            guard written?.map({ [$0.minutes: $0.rate] }) == therapy.basals.map({ [$0.minutes: $0.rate] }),
                  ratios?.schedule.map({ [$0.offset: $0.ratio] })
                  == therapy.carbRatios.schedule.map({ [$0.offset: $0.ratio] }),
                  sensitivities?.sensitivities.map({ [$0.offset: $0.sensitivity] })
                  == therapy.sensitivities.sensitivities.map({ [$0.offset: $0.sensitivity] }),
                  targets?.targets.map({ [$0.offset: $0.low] }) == therapy.targets.targets.map({ [$0.offset: $0.low] })
            else {
                throw ProfileSwitchError.settingsNotWritten
            }
        }

        /// Overlays a profile's algorithm settings onto the live ones, key by key.
        ///
        /// Decoding the profile's payload straight into `Preferences` would reset every field it does not
        /// mention to that field's default, and the default for `maxIOB` is zero.
        private func applyPreferences(_ profileSettings: TrioProfileSettings) throws {
            let merged = try Self.overlay(profileSettings, onto: settingsManager.preferences)
            settingsManager.preferences = merged

            // Saving preferences swallows its errors the same way the therapy files do, so the result
            // has to be read back before the switch can claim to have applied them.
            guard let written = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self),
                  written == merged
            else {
                throw ProfileSwitchError.preferencesNotWritten
            }
        }

        static func overlay(_ profileSettings: TrioProfileSettings, onto live: Preferences) throws -> Preferences {
            let liveData = try JSONCoding.encoder.encode(live)
            var merged = try JSONCoding.decoder.decode(JSONValue.self, from: liveData).objectValue ?? [:]
            for (key, value) in profileSettings.preferences {
                merged[key] = value
            }
            let mergedData = try JSONCoding.encoder.encode(JSONValue.object(merged))
            return try JSONCoding.decoder.decode(Preferences.self, from: mergedData)
        }
    }
}

enum ProfileSwitchError: LocalizedError {
    case settingsNotWritten
    case preferencesNotWritten
    case pumpWriteTimedOut
    case pumpSettingsNotWritten

    var errorDescription: String? {
        switch self {
        case .settingsNotWritten:
            return String(
                localized: "Trio could not save the new therapy settings. Your pump has the new basal rates but Trio is still using the old settings — check your basal rates before dosing."
            )
        case .pumpSettingsNotWritten:
            return String(
                localized: "Trio could not apply the profile's insulin duration, maximum bolus and maximum basal. Nothing else was changed. Check these settings before dosing."
            )
        case .pumpWriteTimedOut:
            return String(
                localized: "Your pump did not confirm the new basal rates in time. Trio kept its old settings, but the pump may still take the new rates — check your pump's basal rates before dosing, or switch again."
            )
        case .preferencesNotWritten:
            return String(
                localized: "Trio applied the new therapy settings but could not save the profile's algorithm settings. Check your algorithm settings before dosing."
            )
        }
    }
}

/// The reply to one pump command, or the lack of one by a deadline. Settles once: whichever of the
/// reply and the deadline comes first wins, and the other is ignored.
actor PumpWriteOutcome {
    private var result: Result<Void, Error>?
    private var expired = false
    private var waiter: CheckedContinuation<Result<Void, Error>?, Never>?

    /// Returns false when the reply came too late to count.
    @discardableResult func finish(_ result: Result<Void, Error>) -> Bool {
        guard self.result == nil, !expired else { return false }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
        return true
    }

    func expire() {
        guard result == nil, !expired else { return }
        expired = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    /// The reply, or nil if the deadline passed first.
    func wait() async -> Result<Void, Error>? {
        if let result { return result }
        if expired { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }
}
