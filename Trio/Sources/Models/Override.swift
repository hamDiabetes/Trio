import Foundation

struct Override {
    let name: String
    let enabled: Bool
    let date: Date
    let duration: Decimal
    let indefinite: Bool
    let percentage: Double
    let smbIsOff: Bool
    let isPreset: Bool
    let id: String
    let overrideTarget: Bool
    let target: Decimal
    let advancedSettings: Bool
    let isfAndCr: Bool
    let isf: Bool
    let cr: Bool
    let smbIsScheduledOff: Bool
    let start: Decimal
    let end: Decimal
    let smbMinutes: Decimal
    let uamMinutes: Decimal
    /// mg/dL. nil keeps the global Enable SMB With High Glucose target.
    var smbHighBgTarget: Decimal?
}

extension Override {
    static let smbHighBgTargetRange: ClosedRange<Decimal> = 120 ... 200
    static let smbHighBgTargetOptions =
        Array(stride(from: smbHighBgTargetRange.lowerBound, through: smbHighBgTargetRange.upperBound, by: 5))

    /// Values outside the range are dropped rather than clamped, so a bad value can never lower the threshold.
    static func validSmbHighBgTarget(_ value: Decimal?) -> Decimal? {
        guard let value, smbHighBgTargetRange.contains(value) else { return nil }
        return value
    }
}
