import Foundation
import Testing
@testable import Trio

@Suite("Profile switch") struct ProfileSwitchTests {
    private func timevalues(_ pairs: [(String, Decimal)]) -> [NightscoutTimevalue] {
        pairs.map { NightscoutTimevalue(time: $0.0, value: $0.1, timeAsSeconds: nil) }
    }

    private func therapy(
        basals: [(String, Decimal)] = [("00:00", 0.45)],
        sens: [(String, Decimal)] = [("00:00", 80)],
        ratios: [(String, Decimal)] = [("00:00", 18)],
        targets: [(String, Decimal)] = [("00:00", 100)]
    ) -> NightscoutTherapySettings {
        NightscoutTherapySettings(
            targets: BGTargets(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                targets: targets.map {
                    BGTargetEntry(low: $0.1, high: $0.1, start: $0.0, offset: NightscoutProfileConverter.offset($0.0) / 60)
                }
            ),
            basals: basals.map {
                BasalProfileEntry(start: $0.0, minutes: NightscoutProfileConverter.offset($0.0) / 60, rate: $0.1)
            },
            carbRatios: CarbRatios(
                units: .grams,
                schedule: ratios.map {
                    CarbRatioEntry(start: $0.0, offset: NightscoutProfileConverter.offset($0.0) / 60, ratio: $0.1)
                }
            ),
            sensitivities: InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: sens.map {
                    InsulinSensitivityEntry(
                        sensitivity: $0.1,
                        offset: NightscoutProfileConverter.offset($0.0) / 60,
                        start: $0.0
                    )
                }
            ),
            units: "mg/dl"
        )
    }

    private func pump(dia: Decimal = 6, maxBolus: Decimal = 3, maxBasal: Decimal = 2) -> PumpSettings {
        PumpSettings(insulinActionCurve: dia, maxBolus: maxBolus, maxBasal: maxBasal)
    }

    // MARK: - Algorithm settings overlay

    // The reason a profile stores every preference key rather than only the ones it changes: decoding a
    // partial payload into Preferences resets every absent field to its default, and maxIOB's default
    // is zero, which blocks every SMB and every positive temp basal.
    @Test("Decoding a partial payload into Preferences zeroes maxIOB") func partialDecodeIsDestructive() throws {
        let partial = #"{"enableUAM": false}"#.data(using: .utf8)!
        let decoded = try JSONCoding.decoder.decode(Preferences.self, from: partial)

        #expect(decoded.maxIOB == 0)
        #expect(decoded.enableUAM == false)
    }

    @Test("Overlaying a profile's settings keeps the fields it does not mention") func overlayPreservesOthers() throws {
        var live = Preferences()
        live.maxIOB = 9
        live.enableUAM = true
        live.maxSMBBasalMinutes = 90

        let profile = TrioProfileSettings(preferences: ["enableUAM": .bool(false)])
        let result = try Profiles.SwitchService.overlay(profile, onto: live)

        #expect(result.enableUAM == false)
        #expect(result.maxIOB == 9)
        #expect(result.maxSMBBasalMinutes == 90)
    }

    @Test("A profile saved from live preferences carries every field") func savedProfileIsComplete() throws {
        var live = Preferences()
        live.maxIOB = 7
        let saved = try TrioProfileSettings(from: live, pumpSettings: pump())

        // Stored under oref's own key names, which is what preferences.json uses.
        #expect(saved.preferences["max_iob"] == .number(7))
        #expect(saved.preferences["enableUAM"] != nil)
        #expect(saved.preferences["autosens_max"] != nil)
        #expect(saved.preferences.count > 40)
    }

    // MARK: - Confirmation preview

    @Test("The preview lists therapy values that differ") func previewListsTherapyChanges() {
        let preview = ProfileSwitchPreview(
            incoming: therapy(basals: [("00:00", 0.6)]),
            current: therapy(basals: [("00:00", 0.45)]),
            currentPreferences: Preferences(),
            currentPumpSettings: pump(),
            profileSettings: nil,
            hasTargetRange: false
        )

        #expect(preview.therapyChanges.contains { $0.label == String(localized: "Basal Rates") })
        #expect(!preview.therapyChanges.contains { $0.label == String(localized: "Carb Ratios") })
        #expect(preview.therapyOnly)
    }

    @Test("The preview is empty when a profile matches the live settings") func previewEmptyWhenIdentical() {
        let preview = ProfileSwitchPreview(
            incoming: therapy(),
            current: therapy(),
            currentPreferences: Preferences(),
            currentPumpSettings: pump(),
            profileSettings: try? TrioProfileSettings(from: Preferences(), pumpSettings: pump()),
            hasTargetRange: false
        )

        #expect(preview.therapyChanges.isEmpty)
        #expect(preview.preferenceChanges.isEmpty)
        #expect(!preview.therapyOnly)
    }

    @Test("The preview lists only the algorithm settings that differ") func previewListsPreferenceChanges() throws {
        var live = Preferences()
        live.enableUAM = true
        live.maxIOB = 9

        var incoming = live
        incoming.enableUAM = false

        let preview = ProfileSwitchPreview(
            incoming: therapy(),
            current: therapy(),
            currentPreferences: live,
            currentPumpSettings: pump(),
            profileSettings: try TrioProfileSettings(from: incoming, pumpSettings: pump()),
            hasTargetRange: false
        )

        #expect(preview.preferenceChanges.count == 1)
        #expect(preview.preferenceChanges.first?.label == "Enable UAM")
        #expect(preview.preferenceChanges.first?.from == "On")
        #expect(preview.preferenceChanges.first?.to == "Off")
    }

    // Justin's rule: a dosing limit gets a row only when the switch actually moves it.
    @Test("Dosing limits are listed only when they change") func previewListsOnlyChangedLimits() throws {
        let preview = ProfileSwitchPreview(
            incoming: therapy(),
            current: therapy(),
            currentPreferences: Preferences(),
            currentPumpSettings: pump(dia: 6, maxBolus: 3, maxBasal: 2),
            profileSettings: try TrioProfileSettings(from: Preferences(), pumpSettings: pump(dia: 6, maxBolus: 5, maxBasal: 2)),
            hasTargetRange: false
        )

        #expect(preview.pumpChanges.map(\.label) == [String(localized: "Max Bolus")])
        #expect(preview.pumpChanges.first?.from == "3 U")
        #expect(preview.pumpChanges.first?.to == "5 U")
        #expect(preview.carriesPumpSettings)
    }

    @Test("A profile saved without dosing limits says they stay") func previewWithoutLimits() {
        let preview = ProfileSwitchPreview(
            incoming: therapy(),
            current: therapy(),
            currentPreferences: Preferences(),
            currentPumpSettings: pump(),
            profileSettings: TrioProfileSettings(preferences: [:]),
            hasTargetRange: false
        )

        #expect(preview.pumpChanges.isEmpty)
        #expect(!preview.carriesPumpSettings)
    }

    // Profiles saved before dosing limits were carried have no such key, and must still load.
    @Test("Settings saved before dosing limits were carried still decode") func legacySettingsDecode() throws {
        let legacy = #"{"preferences": {"max_iob": 4}}"#.data(using: .utf8)!
        let decoded = try JSONCoding.decoder.decode(TrioProfileSettings.self, from: legacy)
        #expect(decoded.pumpSettings == nil)
        #expect(decoded.preferences["max_iob"] == .number(4))
    }

    // MARK: - Dosing limit validation

    @Test("Dosing limits outside Trio's own ranges block a switch") func limitsOutsideRangeBlock() {
        let blocks = Profiles.SwitchService.limitBlocks(
            basals: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.5)],
            incoming: pump(dia: 4, maxBolus: 31, maxBasal: 0.4),
            live: pump()
        )

        #expect(blocks.contains(.pumpLimitOutOfRange(.dia, 4)))
        #expect(blocks.contains(.pumpLimitOutOfRange(.maxBolus, 31)))
        #expect(blocks.contains(.pumpLimitOutOfRange(.maxBasal, 0.4)))
    }

    @Test("Dosing limits at the edges of the ranges are allowed") func limitsAtEdgesAllowed() {
        #expect(Profiles.SwitchService.limitBlocks(
            basals: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.5)],
            incoming: pump(dia: 5, maxBolus: 0.5, maxBasal: 30),
            live: pump()
        ).isEmpty)
        #expect(Profiles.SwitchService.limitBlocks(
            basals: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.5)],
            incoming: pump(dia: 10, maxBolus: 30, maxBasal: 0.5),
            live: pump()
        ).isEmpty)
    }

    // The maximum basal in force after the switch is the profile's own when it carries one, and the
    // live one when it does not.
    @Test("A basal rate above the resulting maximum basal blocks a switch") func basalAboveMaxBasal() {
        let basals = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1.5)]

        #expect(
            Profiles.SwitchService.limitBlocks(basals: basals, incoming: pump(maxBasal: 1), live: pump(maxBasal: 2))
                == [.basalAboveMaxBasal(rate: 1.5, maxBasal: 1)]
        )
        #expect(
            Profiles.SwitchService.limitBlocks(basals: basals, incoming: nil, live: pump(maxBasal: 1))
                == [.basalAboveMaxBasal(rate: 1.5, maxBasal: 1)]
        )
        #expect(
            Profiles.SwitchService.limitBlocks(basals: basals, incoming: pump(maxBasal: 2), live: pump(maxBasal: 1))
                .isEmpty
        )
    }

    // MARK: - Pump write deadline

    @Test("A pump reply after the deadline is ignored") func lateReplyIgnored() async {
        let outcome = PumpWriteOutcome()
        await outcome.expire()
        await outcome.finish(.success(()))
        #expect(await outcome.wait() == nil)
    }

    @Test("A pump reply before the deadline wins") func replyBeforeDeadline() async throws {
        let outcome = PumpWriteOutcome()
        await outcome.finish(.success(()))
        await outcome.expire()
        let result = try #require(await outcome.wait())
        #expect((try? result.get()) != nil)
    }

    @Test("A waiter parked before either settles is released by the deadline") func deadlineReleasesWaiter() async {
        let outcome = PumpWriteOutcome()
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await outcome.expire()
        }
        #expect(await outcome.wait() == nil)
    }

    // The deadline paths are where S2 lives: a write that fails after the switch stopped waiting may
    // still have left delivery suspended.
    @Test("A failure after the deadline still recovers delivery") func lateFailureRecovers() async throws {
        let captured = CapturedReply()
        let recovered = ResumeFlag()
        let lateSuccess = ResumeFlag()

        await #expect(throws: ProfileSwitchError.self) {
            try await Profiles.SwitchService.boundedPumpWrite(
                timeout: 0.05,
                send: { reply in captured.reply = reply },
                recoverAfterFailure: { await recovered.set() },
                onLateSuccess: { await lateSuccess.set() }
            )
        }

        captured.reply?(.failure(URLError(.timedOut)))
        #expect(await eventually { await recovered.value })
        #expect(await !lateSuccess.value)
    }

    @Test("A success after the deadline is recorded, not dropped") func lateSuccessRecorded() async throws {
        let captured = CapturedReply()
        let recovered = ResumeFlag()
        let lateSuccess = ResumeFlag()

        await #expect(throws: ProfileSwitchError.self) {
            try await Profiles.SwitchService.boundedPumpWrite(
                timeout: 0.05,
                send: { reply in captured.reply = reply },
                recoverAfterFailure: { await recovered.set() },
                onLateSuccess: { await lateSuccess.set() }
            )
        }

        captured.reply?(.success(()))
        #expect(await eventually { await lateSuccess.value })
        #expect(await !recovered.value)
    }

    @Test("A failure in time recovers delivery and is reported") func failureInTime() async {
        let recovered = ResumeFlag()
        let lateSuccess = ResumeFlag()

        await #expect(throws: URLError.self) {
            try await Profiles.SwitchService.boundedPumpWrite(
                timeout: 5,
                send: { reply in reply(.failure(URLError(.cannotConnectToHost))) },
                recoverAfterFailure: { await recovered.set() },
                onLateSuccess: { await lateSuccess.set() }
            )
        }
        #expect(await recovered.value)
        #expect(await !lateSuccess.value)
    }

    @Test("A success in time neither recovers nor records") func successInTime() async throws {
        let recovered = ResumeFlag()
        let lateSuccess = ResumeFlag()

        try await Profiles.SwitchService.boundedPumpWrite(
            timeout: 5,
            send: { reply in reply(.success(())) },
            recoverAfterFailure: { await recovered.set() },
            onLateSuccess: { await lateSuccess.set() }
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await !recovered.value)
        #expect(await !lateSuccess.value)
    }

    @Test("A marker written before switches were identified still decodes") func legacyMarkerDecodes() throws {
        let legacy =
            #"{"profileName": "Tianna", "startedAt": "2026-08-13T20:10:24.641Z", "pumpWriteConfirmed": false, "settingsWritten": false}"#
        let marker = try JSONCoding.decoder.decode(ProfileSwitchMarker.self, from: legacy.data(using: .utf8)!)
        #expect(marker.switchID == nil)
        #expect(marker.pumpAcceptedAfterTimeout == nil)
    }

    @Test("A target range is reported so it is not applied unannounced") func previewReportsTargetRange() {
        let preview = ProfileSwitchPreview(
            incoming: therapy(),
            current: therapy(),
            currentPreferences: Preferences(),
            currentPumpSettings: pump(),
            profileSettings: nil,
            hasTargetRange: true
        )

        #expect(preview.hasTargetRange)
    }

    // MARK: - Interrupted switch

    // The marker exists so an interrupted switch can say which side is unknown. Each stage has to be
    // distinguishable, because the advice differs: check the pump, or check Trio's settings.
    @Test("The marker distinguishes how far a switch got") func markerStages() throws {
        let started = ProfileSwitchMarker(
            profileName: "Tianna",
            startedAt: Date(),
            pumpWriteConfirmed: false,
            settingsWritten: false
        )
        let pumped = ProfileSwitchMarker(
            profileName: "Tianna",
            startedAt: Date(),
            pumpWriteConfirmed: true,
            settingsWritten: false
        )

        #expect(!started.pumpWriteConfirmed)
        #expect(pumped.pumpWriteConfirmed)
        #expect(!pumped.settingsWritten)

        // It has to survive being written to disk and read back, or an interrupted switch is silent.
        let data = try JSONCoding.encoder.encode(pumped)
        let restored = try JSONCoding.decoder.decode(ProfileSwitchMarker.self, from: data)
        #expect(restored.profileName == pumped.profileName)
        #expect(restored.pumpWriteConfirmed)
        #expect(!restored.settingsWritten)
    }

    // MARK: - Round trip

    // Switching has to be idempotent: saving the live settings as a profile and reading that profile
    // back must give the same numbers, or A -> B -> A drifts.
    @Test("Saving and re-reading a profile preserves every value") func roundTripIsStable() throws {
        let original = therapy(
            basals: [("00:00", 0.45), ("06:30", 0.35)],
            sens: [("00:00", 47.5)],
            ratios: [("00:00", 8.3)],
            targets: [("00:00", 100)]
        )

        let published = NightscoutProfileConverter.nightscoutProfile(
            from: original,
            units: .mgdL,
            dia: 6,
            carbsPerHour: 24
        )
        let readBack = try NightscoutProfileConverter.therapySettings(from: published)

        #expect(readBack.basals.map(\.rate) == original.basals.map(\.rate))
        #expect(readBack.basals.map(\.minutes) == original.basals.map(\.minutes))
        #expect(
            readBack.sensitivities.sensitivities.map(\.sensitivity)
                == original.sensitivities.sensitivities.map(\.sensitivity)
        )
        #expect(readBack.carbRatios.schedule.map(\.ratio) == original.carbRatios.schedule.map(\.ratio))
        #expect(readBack.targets.targets.map(\.low) == original.targets.targets.map(\.low))
    }

    // The encoder's key order is not stable between calls. A fingerprint built on it made every
    // applied profile read as edited.
    @Test("The applied-profile fingerprint is the same every time") func fingerprintIsStable() {
        let prints = Set((0 ..< 20).map { _ in
            Profiles.Provider.fingerprint(therapy: therapy(), preferences: Preferences(), pumpSettings: pump())
        })
        #expect(prints.count == 1)
    }

    @Test("The fingerprint changes when a dosing limit does") func fingerprintSeesLimits() {
        #expect(
            Profiles.Provider.fingerprint(therapy: therapy(), preferences: Preferences(), pumpSettings: pump(maxBolus: 3))
                != Profiles.Provider.fingerprint(therapy: therapy(), preferences: Preferences(), pumpSettings: pump(maxBolus: 4))
        )
    }

    @Test("Preference keys are shown under readable names") func readableNames() {
        #expect(ProfileSwitchPreview.readableName(for: "max_iob") == "Max IOB")
        #expect(ProfileSwitchPreview.readableName(for: "enableUAM") == "Enable UAM")
        #expect(ProfileSwitchPreview.readableName(for: "maxSMBBasalMinutes") == "Max SMB Basal Minutes")
        #expect(ProfileSwitchPreview.readableName(for: "enableSMB_high_bg") == "Enable SMB High BG")
        #expect(ProfileSwitchPreview.readableName(for: "autosens_max") == "Autosens Max")
    }

    // Decides whether a running temp basal is protection against a low, so an off-by-one at a block
    // boundary lets a switch cancel a zero temp.
    @Test("The scheduled rate is the block that has started") func scheduledRateLookup() {
        let profile = [
            BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.45),
            BasalProfileEntry(start: "06:30", minutes: 390, rate: 0.6),
            BasalProfileEntry(start: "22:00", minutes: 1320, rate: 0.35)
        ]

        #expect(Profiles.SwitchService.scheduledRate(in: profile, atMinute: 0) == 0.45)
        #expect(Profiles.SwitchService.scheduledRate(in: profile, atMinute: 389) == 0.45)
        #expect(Profiles.SwitchService.scheduledRate(in: profile, atMinute: 390) == 0.6)
        #expect(Profiles.SwitchService.scheduledRate(in: profile, atMinute: 1439) == 0.35)
        #expect(Profiles.SwitchService.scheduledRate(in: [], atMinute: 600) == 0)
    }

    @Test("Every failure a switch can report explains what to check") func errorsExplainThemselves() {
        for error in [ProfileSwitchError.settingsNotWritten, .preferencesNotWritten] {
            let message = error.errorDescription ?? ""
            #expect(message.contains("before dosing"))
        }
    }

    @Test("A blocked switch explains itself") func blocksHaveMessages() {
        let blocks: [ProfileSwitchBlock] = [
            .noPump, .pumpSuspended, .bolusInProgress, .looping,
            .reducedTempBasalRunning, .unsupportedBasalRate(0.325)
        ]

        for block in blocks {
            #expect(block.errorDescription?.isEmpty == false)
        }
    }

    // MARK: - Loop exclusion

    @Test("A held exclusion refuses a loop") func exclusionRefusesLoop() async {
        let loopGuard = LoopGuard()
        let token = await loopGuard.tryExclude()
        #expect(token != nil)
        #expect(await !loopGuard.tryStart(minInterval: 0, lastLoopDate: .distantPast, lastLoopStartDate: .distantPast))
    }

    @Test("A running loop refuses an exclusion") func loopRefusesExclusion() async {
        let loopGuard = LoopGuard()
        #expect(await loopGuard.tryStart(minInterval: 0, lastLoopDate: .distantPast, lastLoopStartDate: .distantPast))
        #expect(await loopGuard.tryExclude() == nil)
    }

    @Test("Releasing an exclusion lets the loop run again") func releaseRestoresLooping() async throws {
        let loopGuard = LoopGuard()
        let token = try #require(await loopGuard.tryExclude())
        await loopGuard.endExclusion(token)
        #expect(await loopGuard.tryStart(minInterval: 0, lastLoopDate: .distantPast, lastLoopStartDate: .distantPast))
    }

    // A person switching profiles is not a loop and should not wait out the loop interval.
    @Test("The loop interval does not refuse an exclusion") func intervalDoesNotRefuseExclusion() async {
        let loopGuard = LoopGuard()
        let justNow = Date()
        #expect(await !loopGuard.tryStart(
            minInterval: 180,
            lastLoopDate: justNow,
            lastLoopStartDate: justNow.addingTimeInterval(-1)
        ))
        #expect(await loopGuard.tryExclude() != nil)
    }

    @Test("A stale token cannot release a later exclusion") func staleTokenIgnored() async throws {
        let loopGuard = LoopGuard()
        let first = try #require(await loopGuard.tryExclude())
        await loopGuard.endExclusion(first)
        _ = try #require(await loopGuard.tryExclude())
        await loopGuard.endExclusion(first)
        #expect(await !loopGuard.tryStart(minInterval: 0, lastLoopDate: .distantPast, lastLoopStartDate: .distantPast))
    }

    // The switch recalculates after releasing, and the recalculation waits on the guard. If a waiter
    // parked during an exclusion were only woken by a loop finishing, the switch would hang and Trio
    // would stop looping.
    @Test("A determination waiting on an exclusion resumes when it is released") func waiterResumesOnRelease() async throws {
        let loopGuard = LoopGuard()
        let token = try #require(await loopGuard.tryExclude())

        let resumed = ResumeFlag()
        Task {
            await loopGuard.waitForLoop()
            await resumed.set()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await !resumed.value)

        await loopGuard.endExclusion(token)

        // Polled rather than awaited, so a waiter that never resumes fails the test instead of hanging it.
        var finished = false
        for _ in 0 ..< 40 where !finished {
            try await Task.sleep(nanoseconds: 50_000_000)
            finished = await resumed.value
        }
        #expect(finished)
    }
}

private actor ResumeFlag {
    private(set) var value = false
    func set() { value = true }
}

private final class CapturedReply: @unchecked Sendable {
    var reply: ((Result<Void, Error>) -> Void)?
}

/// Polls for up to two seconds, so a condition that never becomes true fails rather than hangs.
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0 ..< 40 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}
