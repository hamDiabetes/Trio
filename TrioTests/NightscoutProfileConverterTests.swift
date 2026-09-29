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
}
