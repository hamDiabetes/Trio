import Foundation
import Testing
@testable import Trio

@Suite("Nightscout profile conversion") struct NightscoutProfileConverterTests {
    private func timevalues(_ pairs: [(String, Decimal)]) -> [NightscoutTimevalue] {
        pairs.map { NightscoutTimevalue(time: $0.0, value: $0.1, timeAsSeconds: nil) }
    }

    private func profile(
        units: String = "mg/dl",
        targetLow: [(String, Decimal)] = [("00:00", 100)],
        targetHigh: [(String, Decimal)]? = nil,
        sens: [(String, Decimal)] = [("00:00", 80)],
        basal: [(String, Decimal)] = [("00:00", 0.45)],
        carbratio: [(String, Decimal)] = [("00:00", 18)]
    ) -> ScheduledNightscoutProfile {
        ScheduledNightscoutProfile(
            dia: 6,
            carbs_hr: 24,
            delay: 0,
            timezone: "America/Boise",
            target_low: timevalues(targetLow),
            target_high: timevalues(targetHigh ?? targetLow),
            sens: timevalues(sens),
            basal: timevalues(basal),
            carbratio: timevalues(carbratio),
            units: units
        )
    }

    @Test("A mg/dL profile converts without touching its values") func mgdlPassesThrough() throws {
        let settings = try NightscoutProfileConverter.therapySettings(from: profile())
        #expect(settings.targets.targets.first?.low == 100)
        #expect(settings.sensitivities.sensitivities.first?.sensitivity == 80)
        #expect(settings.basals.first?.rate == 0.45)
        #expect(settings.carbRatios.schedule.first?.ratio == 18)
    }

    @Test("An mmol/L profile converts to mg/dL") func mmolConverts() throws {
        let settings = try NightscoutProfileConverter.therapySettings(
            from: profile(units: "mmol", targetLow: [("00:00", 5.5)], sens: [("00:00", 4.4)])
        )
        let target = try #require(settings.targets.targets.first?.low)
        let isf = try #require(settings.sensitivities.sensitivities.first?.sensitivity)
        #expect(target > 95 && target < 105)
        #expect(isf > 75 && isf < 85)
    }

    @Test("Time strings become minute offsets") func timeOffsets() throws {
        let settings = try NightscoutProfileConverter.therapySettings(
            from: profile(basal: [("00:00", 0.4), ("06:30", 0.5)])
        )
        #expect(settings.basals.map(\.minutes) == [0, 390])
    }

    // A placeholder target of 0 is the realistic way the mmol guess is defeated: it reads as mmol/L
    // and every sensitivity is then multiplied by 18.
    @Test("A zero target is rejected rather than read as mmol/L") func zeroTargetRejected() {
        #expect(throws: NightscoutProfileImportError.self) {
            try NightscoutProfileConverter.therapySettings(from: profile(targetLow: [("00:00", 0)]))
        }
    }

    @Test("A profile with no targets is rejected") func missingTargetsRejected() {
        #expect(throws: NightscoutProfileImportError.self) {
            try NightscoutProfileConverter.therapySettings(from: profile(targetLow: []))
        }
    }

    @Test("A profile labelled mmol/L carrying mg/dL values is rejected") func ambiguousUnitsRejected() {
        #expect(throws: NightscoutProfileImportError.self) {
            try NightscoutProfileConverter.therapySettings(
                from: profile(units: "mmol", targetLow: [("00:00", 100)])
            )
        }
    }

    @Test("Non-positive rates and ratios are rejected") func nonPositiveRejected() {
        #expect(throws: NightscoutProfileImportError.self) {
            try NightscoutProfileConverter.therapySettings(from: profile(basal: [("00:00", 0)]))
        }
        #expect(throws: NightscoutProfileImportError.self) {
            try NightscoutProfileConverter.therapySettings(from: profile(carbratio: [("00:00", 0)]))
        }
        #expect(throws: NightscoutProfileImportError.self) {
            try NightscoutProfileConverter.therapySettings(from: profile(sens: [("00:00", 0)]))
        }
    }

    @Test("A target range is reported rather than silently imported as its lower bound") func targetRangeDetected() {
        #expect(NightscoutProfileConverter.hasTargetRange(
            profile(targetLow: [("00:00", 80)], targetHigh: [("00:00", 180)])
        ))
        #expect(!NightscoutProfileConverter.hasTargetRange(profile()))
    }

    @Test("Odd time formats from other apps parse to the right hour") func timeFormats() {
        #expect(NightscoutProfileConverter.offset("06:30") == 23400)
        #expect(NightscoutProfileConverter.offset("6:30") == 23400)
        #expect(NightscoutProfileConverter.offset("06:30:00") == 23400)
        #expect(NightscoutProfileConverter.offset("00:00") == 0)
    }

    @Test("A profile with mismatched target array lengths counts as a range") func mismatchedTargetCounts() {
        #expect(NightscoutProfileConverter.hasTargetRange(
            profile(targetLow: [("00:00", 100)], targetHigh: [("00:00", 100), ("12:00", 110)])
        ))
    }

    // Therapy values pass through a JSON round trip on every profile upload. JSONSerialization would
    // re-emit 0.45 as 0.45000000000000001, and the editors match rates by exact equality.
    @Test("A therapy value survives the document round trip exactly") func roundTripKeepsPrecision() throws {
        let entry = profile(sens: [("00:00", 47.5)], basal: [("00:00", 0.45)], carbratio: [("00:00", 8.3)])
        let encoded = try JSONCoding.encoder.encode(entry)
        let value = try JSONCoding.decoder.decode(JSONValue.self, from: encoded)
        let reencoded = try JSONCoding.encoder.encode(value)
        let decoded = try JSONCoding.decoder.decode(ScheduledNightscoutProfile.self, from: reencoded)

        #expect(decoded.basal.first?.value == 0.45)
        #expect(decoded.sens.first?.value == 47.5)
        #expect(decoded.carbratio.first?.value == 8.3)
    }

    @Test("A foreign profile survives a document round trip untouched") func foreignProfileUnchanged() throws {
        let document = JSONValue.object([
            "_id": .string("6a7df3d1aaaaaaaaaaaaaaaa"),
            "store": .object(["Tianna": .number(0.35), "default": .number(0.45)]),
            "somethingTrioDoesNotModel": .array([.string("keep"), .bool(true), .null])
        ])
        let reencoded = try JSONCoding.encoder.encode(document)
        let decoded = try JSONCoding.decoder.decode(JSONValue.self, from: reencoded)
        #expect(decoded == document)
    }

    // One hand-edited entry must not hide the rest, and must not vanish without a word either.
    @Test("An unreadable profile is named and the others still load") func unreadableEntryNamed() throws {
        let document = #"""
        {"Good": {"dia": 6, "carbs_hr": 20, "delay": 20, "timezone": "UTC", "units": "mg/dl",
                  "target_low": [{"time": "00:00", "value": 100}], "target_high": [{"time": "00:00", "value": 100}],
                  "sens": [{"time": "00:00", "value": 80}], "basal": [{"time": "00:00", "value": 0.5}],
                  "carbratio": [{"time": "00:00", "value": 10}]},
         "Broken": {"dia": 6, "basal": "not a schedule"}}
        """#
        let store = try JSONCoding.decoder.decode(JSONValue.self, from: document.data(using: .utf8)!).objectValue ?? [:]
        let contents = NightscoutAPI.readStore(store)

        #expect(Array(contents.profiles.keys) == ["Good"])
        #expect(contents.unreadable == ["Broken"])
    }

    @Test("Schedules are put in time order") func schedulesSorted() throws {
        let settings = try NightscoutProfileConverter.therapySettings(from: profile(
            targetLow: [("12:00", 110), ("00:00", 100)],
            sens: [("18:00", 90), ("00:00", 80)],
            basal: [("00:00", 0.45), ("12:00", 0.5), ("06:00", 0.6)],
            carbratio: [("06:00", 12), ("00:00", 18)]
        ))
        #expect(settings.basals.map(\.minutes) == [0, 360, 720])
        #expect(settings.carbRatios.schedule.map(\.offset) == [0, 360])
        #expect(settings.sensitivities.sensitivities.map(\.offset) == [0, 1080])
        #expect(settings.targets.targets.map(\.offset) == [0, 720])
    }

    @Test("A schedule that misses midnight or repeats a time is refused") func malformedSchedulesRefused() {
        for bad in [
            profile(basal: [("01:00", 0.45)]),
            profile(basal: [("00:00", 0.45), ("06:00", 0.5), ("06:00", 0.6)]),
            profile(carbratio: [("06:00", 12)]),
            profile(sens: [("00:00", 80), ("00:00", 90)]),
            profile(targetLow: [("08:00", 100)])
        ] {
            #expect(throws: NightscoutProfileImportError.malformedSchedule) {
                try NightscoutProfileConverter.therapySettings(from: bad)
            }
        }
    }

    // An mmol sensitivity typed into a mg/dL profile reads as far more aggressive than meant.
    @Test("Sensitivities and ratios outside the editors' ranges are refused") func editorRangesEnforced() throws {
        #expect(throws: NightscoutProfileImportError.sensitivityOutOfRange(8)) {
            try NightscoutProfileConverter.therapySettings(from: profile(sens: [("00:00", 8)]))
        }
        #expect(throws: NightscoutProfileImportError.sensitivityOutOfRange(541)) {
            try NightscoutProfileConverter.therapySettings(from: profile(sens: [("00:00", 541)]))
        }
        #expect(throws: NightscoutProfileImportError.carbRatioOutOfRange(0.9)) {
            try NightscoutProfileConverter.therapySettings(from: profile(carbratio: [("00:00", 0.9)]))
        }
        #expect(throws: NightscoutProfileImportError.carbRatioOutOfRange(51)) {
            try NightscoutProfileConverter.therapySettings(from: profile(carbratio: [("00:00", 51)]))
        }
        _ = try NightscoutProfileConverter.therapySettings(from: profile(sens: [("00:00", 9)], carbratio: [("00:00", 1)]))
        _ = try NightscoutProfileConverter.therapySettings(from: profile(sens: [("00:00", 540)], carbratio: [("00:00", 50)]))
    }

    @Test("Targets above the editor's range are refused") func highTargetRefused() throws {
        #expect(throws: NightscoutProfileImportError.implausibleTargets(181)) {
            try NightscoutProfileConverter.therapySettings(from: profile(targetLow: [("00:00", 181)]))
        }
        _ = try NightscoutProfileConverter.therapySettings(from: profile(targetLow: [("00:00", 180)]))
    }

    // MARK: - Profile document merge

    private func document() throws -> [String: JSONValue] {
        let text = #"""
        {"_id": "abc", "startDate": "2026-08-01T00:00:00.000Z", "mills": 1785542400000, "custom": "keep",
         "deviceToken": "old", "store": {"default": {"dia": 6}, "Tianna": {"dia": 7}}}
        """#
        return try JSONCoding.decoder.decode(JSONValue.self, from: text.data(using: .utf8)!).objectValue ?? [:]
    }

    @Test("Publishing Trio's entry keeps every other profile and key") func mergeKeepsOthers() throws {
        let own: [String: JSONValue] = ["deviceToken": .string("new"), "startDate": .string("now"), "mills": .number(1)]
        let merged = try BaseNightscoutManager.mergedProfileDocument(document()) { fields, store in
            BaseNightscoutManager.mergeOwnProfile(
                own,
                entry: .object(["dia": .number(5)]),
                named: "default",
                into: &fields,
                store: &store
            )
        }

        #expect(merged["store"]?["Tianna"] == .object(["dia": .number(7)]))
        #expect(merged["store"]?["default"] == .object(["dia": .number(5)]))
        #expect(merged["custom"] == .string("keep"))
        #expect(merged["_id"] == .string("abc"))
        #expect(merged["deviceToken"] == .string("new"))
        // Advancing these would make the document newer than every Profile Switch treatment.
        #expect(merged["startDate"] == .string("2026-08-01T00:00:00.000Z"))
        #expect(merged["mills"] == .number(1_785_542_400_000))
    }

    @Test("A document without a readable store is not rebuilt around Trio's entry") func missingStoreRefused() throws {
        var bad = try document()
        bad["store"] = .string("not a store")
        #expect(throws: URLError.self) {
            _ = try BaseNightscoutManager.mergedProfileDocument(bad) { _, store in store["default"] = .null }
        }
    }

    @Test("A profile switch is recorded as an indefinite switch to the named profile") func switchTreatmentFields() throws {
        let data = try JSONCoding.encoder.encode(
            BaseNightscoutManager.profileSwitchTreatment(name: "Tianna", profile: profile(), at: Date())
        )
        let fields = try JSONCoding.decoder.decode(JSONValue.self, from: data)
        #expect(fields["eventType"] == .string("Profile Switch"))
        #expect(fields["profile"] == .string("Tianna"))
        #expect(fields["duration"] == .number(0))
        #expect(fields["profileJson"]?.stringValue?.contains("\"basal\"") == true)
    }
}
