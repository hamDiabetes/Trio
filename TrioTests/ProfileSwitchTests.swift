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

    @Test("A waiter parked before either settles is released by the deadline") func deadlineReleasesWaiter() async throws {
        let outcome = PumpWriteOutcome()
        let released = ResumeFlag()
        Task {
            _ = await outcome.wait()
            await released.set()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await !released.value)
        await outcome.expire()
        #expect(await eventually { await released.value })
    }

    // Some pump managers call back twice. A repeated failure must not resume delivery a second time.
    @Test("A repeated reply is acted on once") func duplicateReplyIgnored() async throws {
        let recoveries = Counter()
        await #expect(throws: URLError.self) {
            try await Profiles.SwitchService.boundedPumpWrite(
                timeout: 5,
                send: { reply in
                    reply(.failure(URLError(.cannotConnectToHost)))
                    reply(.failure(URLError(.cannotConnectToHost)))
                },
                recoverAfterFailure: { await recoveries.increment() },
                onLateSuccess: {}
            )
        }
        #expect(await eventually { await recoveries.value == 1 })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await recoveries.value == 1)
    }

    // A slow recovery must not turn a failure the pump reported in time into a timeout.
    @Test("A failure is reported as itself even when recovery is slow") func slowRecoveryKeepsError() async {
        await #expect(throws: URLError.self) {
            try await Profiles.SwitchService.boundedPumpWrite(
                timeout: 0.2,
                send: { reply in reply(.failure(URLError(.cannotConnectToHost))) },
                recoverAfterFailure: { try? await Task.sleep(nanoseconds: 1_000_000_000) },
                onLateSuccess: {}
            )
        }
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
        try await Task.sleep(nanoseconds: 50_000_000)
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

    // Recovery from a failure in time has to finish before the switch releases the loop, so a loop
    // never starts against a pod still being resumed. A slow recovery shows whether it waited.
    @Test("A failure in time recovers delivery and is reported") func failureInTime() async {
        let recovered = ResumeFlag()
        let lateSuccess = ResumeFlag()

        await #expect(throws: URLError.self) {
            try await Profiles.SwitchService.boundedPumpWrite(
                timeout: 5,
                send: { reply in reply(.failure(URLError(.cannotConnectToHost))) },
                recoverAfterFailure: {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    await recovered.set()
                },
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

    // The encoder's key order is not stable between processes, and the fingerprint is stored across
    // launches. A test in one process cannot see the drift, so it checks the order itself.
    @Test("The applied-profile fingerprint encodes keys in sorted order") func fingerprintKeysSorted() throws {
        let data = try Profiles.Provider.canonicalJSON(BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.45))
        let text = try #require(String(data: data, encoding: .utf8))
        let parts = text.components(separatedBy: "\"")
        let keys = stride(from: 1, to: parts.count - 1, by: 2)
            .filter { parts[$0 + 1].trimmingCharacters(in: .whitespaces).hasPrefix(":") }
            .map { parts[$0] }
        #expect(keys == keys.sorted())
        #expect(keys.count == 3)
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

    @Test("Every failure a switch can report explains what to check") func errorsExplainThemselves() {
        for error in ProfileSwitchError.allCases {
            let message = error.errorDescription ?? ""
            #expect(message.contains("before dosing"))
        }
    }

    @Test("A blocked switch explains itself") func blocksHaveMessages() {
        let blocks: [ProfileSwitchBlock] = [
            .noPump, .pumpSuspended, .bolusInProgress, .looping,
            .reducedTempBasalRunning, .manualTempBasalRunning, .unsupportedBasalRate(0.325), .unreadableSettings
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

    @Test("A waived interval lets a loop start, but not past an exclusion") func waivedIntervalStillHonoursExclusion() async throws {
        let justNow = Date()
        let held = LoopGuard()
        let token = try #require(await held.tryExclude())
        #expect(await !held.tryStart(minInterval: 0, lastLoopDate: justNow, lastLoopStartDate: justNow.addingTimeInterval(-1)))
        await held.endExclusion(token)
        #expect(await held.tryStart(minInterval: 0, lastLoopDate: justNow, lastLoopStartDate: justNow.addingTimeInterval(-1)))
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
        // Released only once the waiter is known to be parked, or the wake-up path is never exercised.
        #expect(await eventually { await loopGuard.waiterCount == 1 })
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

    // MARK: - Preflight as wired

    private func preflight(
        temp: Decimal? = nil,
        scheduled: Decimal? = 0.45,
        suspended: Bool = false,
        bolusing: Bool = false,
        looping: Bool = false,
        openLoop: Bool = false,
        manual: Bool = false
    ) -> ProfileSwitchPreflight {
        ProfileSwitchPreflight(
            suspended: suspended,
            bolusInProgress: bolusing,
            looping: looping,
            automationOff: openLoop,
            manualTempBasal: manual,
            tempBasalRate: temp,
            scheduledRate: scheduled
        )
    }

    private func preflightBlocks(_ preflight: ProfileSwitchPreflight, incoming: PumpSettings? = nil) -> [ProfileSwitchBlock] {
        Profiles.SwitchService.blocks(
            preflight: preflight,
            basals: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.5)],
            incoming: incoming,
            live: pump()
        )
    }

    @Test("With the loop running, a temp basal does not block a switch") func loopTempDoesNotBlock() {
        for temp: Decimal in [0, 0.13, 0.45, 1.2] {
            #expect(preflightBlocks(preflight(temp: temp)).isEmpty)
        }
        #expect(preflightBlocks(preflight(temp: 0, scheduled: nil)).isEmpty)
    }

    @Test("In Open Loop a temp below the schedule blocks, and one at or above it does not") func openLoopReducedTempBlocks() {
        #expect(preflightBlocks(preflight(temp: 0, openLoop: true)) == [.reducedTempBasalRunning])
        #expect(preflightBlocks(preflight(temp: 0.4, openLoop: true)) == [.reducedTempBasalRunning])
        #expect(preflightBlocks(preflight(temp: 0.45, openLoop: true)).isEmpty)
        #expect(preflightBlocks(preflight(temp: 1.2, openLoop: true)).isEmpty)
        #expect(preflightBlocks(preflight(openLoop: true)).isEmpty)
    }

    @Test("In Open Loop a temp blocks when the schedule cannot be read") func unknownScheduleBlocks() {
        #expect(preflightBlocks(preflight(temp: 1.2, scheduled: nil, openLoop: true)) == [.reducedTempBasalRunning])
    }

    @Test("A temp basal set on the pump blocks in any mode") func manualTempBlocks() {
        #expect(preflightBlocks(preflight(temp: 1.2, manual: true)) == [.manualTempBasalRunning])
        #expect(preflightBlocks(preflight(temp: 0, openLoop: true, manual: true)) == [.manualTempBasalRunning])
        #expect(preflightBlocks(preflight(manual: true)).isEmpty)
    }

    @Test("Suspension, a bolus and a running loop each block a switch") func pumpStateBlocks() {
        #expect(preflightBlocks(preflight(suspended: true)) == [.pumpSuspended])
        #expect(preflightBlocks(preflight(bolusing: true)) == [.bolusInProgress])
        #expect(preflightBlocks(preflight(looping: true)) == [.looping])
        #expect(preflightBlocks(preflight()).isEmpty)
    }

    @Test("Preflight checks the profile's own dosing limits") func preflightChecksIncomingLimits() {
        #expect(preflightBlocks(preflight(), incoming: pump(maxBolus: 31)).contains(.pumpLimitOutOfRange(.maxBolus, 31)))
    }

    @Test("Without a pump nothing else is checked but the profile's limits") func noPumpBlocks() {
        #expect(preflightBlocks(ProfileSwitchPreflight(pumpPresent: false)) == [.noPump])
    }

    // MARK: - Holding the loop

    @Test("The loop is released after the work succeeds") func holdReleasedOnSuccess() async throws {
        let ended = ResumeFlag()
        try await Profiles.SwitchService.holdingLoop(begin: { true }, end: { await ended.set() }) {}
        #expect(await ended.value)
    }

    @Test("The loop is released when the work fails") func holdReleasedOnFailure() async {
        let ended = ResumeFlag()
        await #expect(throws: URLError.self) {
            try await Profiles.SwitchService.holdingLoop(begin: { true }, end: { await ended.set() }) {
                throw URLError(.cannotConnectToHost)
            }
        }
        #expect(await ended.value)
    }

    @Test("Nothing runs when the loop cannot be held") func holdRefused() async {
        let ran = ResumeFlag()
        let ended = ResumeFlag()
        await #expect(throws: ProfileSwitchBlock.looping) {
            try await Profiles.SwitchService.holdingLoop(begin: { false }, end: { await ended.set() }) {
                await ran.set()
            }
        }
        #expect(await !ran.value)
        #expect(await !ended.value)
    }

    // MARK: - Order of a switch

    private func runSteps(_ log: StepLog, withLimits: Bool = true, failing: String? = nil) async throws {
        func step(_ name: String) async throws {
            await log.append(name)
            if name == failing { throw URLError(.cannotConnectToHost) }
        }
        try await Profiles.SwitchService.runSteps(
            writeLimits: withLimits ? { try await step("limits") } : nil,
            restoreLimits: { await log.append("restore") },
            writeBasal: { try await step("basal") },
            endAdjustments: { try await step("adjustments") },
            writeSettings: { try await step("settings") }
        )
    }

    @Test("A switch writes limits, then the schedule, then ends adjustments") func stepsInOrder() async throws {
        let log = StepLog()
        try await runSteps(log)
        #expect(await log.entries == ["limits", "basal", "adjustments", "settings"])
    }

    @Test("A failed schedule write restores the limits and ends nothing") func basalFailureRestoresLimits() async {
        let log = StepLog()
        await #expect(throws: URLError.self) { try await runSteps(log, failing: "basal") }
        #expect(await log.entries == ["limits", "basal", "restore"])
    }

    @Test("A failed limit write is restored and goes no further") func limitFailureRestores() async {
        let log = StepLog()
        await #expect(throws: URLError.self) { try await runSteps(log, failing: "limits") }
        #expect(await log.entries == ["limits", "restore"])
    }

    @Test("A failure after the schedule write still restores the limits") func lateFailureRestoresLimits() async {
        let log = StepLog()
        await #expect(throws: URLError.self) { try await runSteps(log, failing: "settings") }
        #expect(await log.entries == ["limits", "basal", "adjustments", "settings", "restore"])
    }

    @Test("A profile without limits has none to restore") func noLimitsNoRestore() async {
        let log = StepLog()
        await #expect(throws: URLError.self) { try await runSteps(log, withLimits: false, failing: "basal") }
        #expect(await log.entries == ["basal"])
    }

    @Test("Limits the pump stored differently are reported as not written") func pumpLimitsReadBack() async throws {
        let asked = PumpSettings(insulinActionCurve: 6, maxBolus: 5, maxBasal: 2)
        let reported = PumpSettings(insulinActionCurve: 6, maxBolus: 3, maxBasal: 2)

        await #expect(throws: ProfileSwitchError.pumpSettingsNotWritten) {
            try await Profiles.SwitchService.savePumpSettings(asked, save: {}, stored: { reported })
        }
        await #expect(throws: ProfileSwitchError.pumpSettingsNotWritten) {
            try await Profiles.SwitchService.savePumpSettings(asked, save: {}, stored: { nil })
        }
        try await Profiles.SwitchService.savePumpSettings(asked, save: {}, stored: { asked })
    }

    // MARK: - Standalone determinations

    @Test("A standalone determination refuses an exclusion") func standaloneRefusesExclusion() async {
        let loopGuard = LoopGuard()
        #expect(await loopGuard.waitAndStartStandaloneDetermination())
        #expect(await loopGuard.tryExclude() == nil)
        await loopGuard.finishStandaloneDetermination()
        #expect(await loopGuard.tryExclude() != nil)
    }

    @Test("A standalone determination waits for an exclusion to end") func standaloneWaitsForExclusion() async throws {
        let loopGuard = LoopGuard()
        let token = try #require(await loopGuard.tryExclude())
        let started = ResumeFlag()
        Task {
            if await loopGuard.waitAndStartStandaloneDetermination() { await started.set() }
        }
        #expect(await eventually { await loopGuard.waiterCount == 1 })
        #expect(await !started.value)
        await loopGuard.endExclusion(token)
        #expect(await eventually { await started.value })
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor ResumeFlag {
    private(set) var value = false
    func set() { value = true }
}

private actor StepLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
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
