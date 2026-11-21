import Foundation

extension RecordRepresentation {
    /// One value of a CloudKit record, tagged with its CloudKit type, so it reads back
    /// exactly as it was stored without a schema.
    ///
    /// Each field encodes as an object with one key, its type, such as `{"string": "Hello"}`
    /// or `{"encrypted": {"int64": 3}}`, so SQLite can query a field by its path and
    /// ``JSONDifference`` can compare two versions of a record.
    enum Field: Hashable, Sendable {
        case string(String)
        case int64(Int64)
        case double(Double)
        case timestamp(Date)
        case bytes(Data)
        case location(Location)
        case reference(Reference)
        case asset(URL?)
        case list([Field])
        /// A value CloudKit stores in `encryptedValues`.
        indirect case encrypted(Field)
    }
}

extension RecordRepresentation.Field: Codable {
    private enum CodingKeys: String, CodingKey {
        case string, int64, double, timestamp, bytes, location, reference, asset, list, encrypted
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A field holds exactly one value, keyed by its CloudKit type."))
        }
        self = switch key {
        case .string: .string(try container.decode(String.self, forKey: key))
        case .int64: .int64(try container.decode(Int64.self, forKey: key))
        case .double: .double(try container.decode(Double.self, forKey: key))
        case .timestamp: .timestamp(try container.decode(Date.self, forKey: key))
        case .bytes: .bytes(try container.decode(Data.self, forKey: key))
        case .location: .location(try container.decode(Location.self, forKey: key))
        case .reference: .reference(try container.decode(RecordRepresentation.Reference.self, forKey: key))
        case .asset: .asset(try container.decode(URL?.self, forKey: key))
        case .list: .list(try container.decode([Self].self, forKey: key))
        case .encrypted: .encrypted(try container.decode(Self.self, forKey: key))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value): try container.encode(value, forKey: .string)
        case .int64(let value): try container.encode(value, forKey: .int64)
        case .double(let value): try container.encode(value, forKey: .double)
        case .timestamp(let value): try container.encode(value, forKey: .timestamp)
        case .bytes(let value): try container.encode(value, forKey: .bytes)
        case .location(let value): try container.encode(value, forKey: .location)
        case .reference(let value): try container.encode(value, forKey: .reference)
        case .asset(let value): try container.encode(value, forKey: .asset)
        case .list(let value): try container.encode(value, forKey: .list)
        case .encrypted(let value): try container.encode(value, forKey: .encrypted)
        }
    }
}
