import Foundation

/// A JSON document Trio reads, edits and writes back without owning all of it.
///
/// `JSONSerialization` parses every non-integer number into a `Double` and re-emits it at full
/// precision, so a basal rate of 0.45 comes back as 0.45000000000000001. That is not acceptable for a
/// Nightscout profile document, where most of the numbers are therapy settings and many of them belong
/// to profiles Trio did not write. `Decimal` decodes from the source text, so values survive a
/// round trip exactly.
indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue {
    /// A value as its own JSON encoding carries it.
    init(encoding value: some Encodable) throws {
        self = try JSONCoding.decoder.decode(JSONValue.self, from: JSONCoding.encoder.encode(value))
    }
}
