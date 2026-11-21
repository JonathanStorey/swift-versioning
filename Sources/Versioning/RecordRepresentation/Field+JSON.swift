import Foundation

extension RecordRepresentation {
    /// A record's fields by key, as CloudKit stores them.
    typealias Fields = [String: Field]
}

extension Dictionary where Key == String, Value == RecordRepresentation.Field {
    /// The fields a record stores for `json`, a value encoded with ``JSONRepresentation/init(_:)``,
    /// each converted to its CloudKit type by `schema`. A `nil` value stores no field.
    init(_ json: JSONRepresentation, schema: RecordSchema) throws {
        guard case .object(let properties) = json else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A \(schema.recordType) record is an object."))
        }
        self = [:]
        for (key, value) in properties {
            guard let declared = schema.fields[key],
                  let field = try RecordRepresentation.Field(value, as: declared.type, schema: declared.schema, at: [key]) else { continue }
            self[key] = declared.isEncrypted ? .encrypted(field) : field
        }
    }
}

extension JSONRepresentation {
    /// The JSON the type behind `schema` decodes from `fields`: the reverse of
    /// `[String: Field](_:schema:)`. Fields the schema does not declare are left out.
    init(_ fields: RecordRepresentation.Fields, schema: RecordSchema) throws {
        var object: Object = []
        for (key, field) in fields.sorted(by: { $0.key < $1.key }) {
            guard let declared = schema.fields[key] else { continue }
            object.append((key: key, value: try field.json(as: declared.type, schema: declared.schema, at: [key])))
        }
        self = .object(object)
    }
}

extension RecordRepresentation.Field {
    /// `json` as a field of CloudKit type `type`, or `nil` for JSON `null`.
    init?(_ json: JSONRepresentation, as type: RecordSchema.FieldType, schema: JSONSchema, at path: [String]) throws {
        if case .null = json { return nil }
        switch (type, json) {
        case let (.string, .string(text)):
            self = .string(text)
        case let (.int64, .bool(flag)):
            self = .int64(flag ? 1 : 0)
        case (.int64, .number):
            guard let value = json.int64Value else { throw Self.mismatch(type, at: path) }
            self = .int64(value)
        case (.double, .number):
            guard let value = json.doubleValue else { throw Self.mismatch(type, at: path) }
            self = .double(value)
        case (.timestamp, .number):
            guard let seconds = json.doubleValue else { throw Self.mismatch(type, at: path) }
            self = .timestamp(Date(timeIntervalSinceReferenceDate: seconds))
        case let (.bytes, .string(text)) where schema.holdsData:
            guard let data = Data(base64Encoded: text) else { throw Self.mismatch(type, at: path) }
            self = .bytes(data)
        case (.bytes, _):
            // A nested value, a dictionary, or a list CloudKit cannot hold, as JSON text.
            self = .bytes(Data(json.description.utf8))
        case (.location, .object):
            self = .location(try json.decode(Location.self))
        case (.reference, .object):
            self = .reference(try json.decode(RecordRepresentation.Reference.self))
        case let (.asset, .string(text)):
            self = .asset(URL(string: text))
        case let (.list(element), .array(items)):
            self = .list(try items.enumerated().map { index, item in
                guard let field = try Self(item, as: element, schema: schema.elements, at: path + [String(index)]) else { throw Self.mismatch(element, at: path) }
                return field
            })
        default:
            throw Self.mismatch(type, at: path)
        }
    }

    /// The JSON this field holds, as the type behind `schema` decodes it.
    func json(as type: RecordSchema.FieldType, schema: JSONSchema, at path: [String]) throws -> JSONRepresentation {
        switch (self, type) {
        case let (.encrypted(value), _):
            return try value.json(as: type, schema: schema, at: path)
        case let (.string(text), .string):
            return .string(text)
        case let (.int64(value), .int64):
            if case .boolean = schema.unwrapped { return .bool(value != 0) }
            return .number(String(value))
        case let (.double(value), .double):
            return try JSONRepresentation(value)
        case let (.timestamp(date), .timestamp):
            return try JSONRepresentation(date)
        case let (.bytes(data), .bytes):
            if schema.holdsData { return .string(data.base64EncodedString()) }
            return try JSONDecoder().decode(JSONRepresentation.self, from: data)
        case let (.location(location), .location):
            return try JSONRepresentation(location)
        case let (.reference(reference), .reference):
            return try JSONRepresentation(reference)
        case let (.asset(url), .asset):
            return url.map { .string($0.absoluteString) } ?? .null
        case let (.list(items), .list(element)):
            return .array(try items.enumerated().map { index, item in
                try item.json(as: element, schema: schema.elements, at: path + [String(index)])
            })
        default:
            throw Self.mismatch(type, at: path)
        }
    }

    private static func mismatch(_ type: RecordSchema.FieldType, at path: [String]) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "The field at \(path.joined(separator: ".")) does not hold a \(type)."))
    }
}

private extension JSONSchema {
    /// Whether `BYTES` holds `Data`, written as Base64, rather than a nested value.
    var holdsData: Bool {
        if case .string = unwrapped { true } else { false }
    }

    /// The schema of a list's elements.
    var elements: JSONSchema {
        switch unwrapped {
        case .array(let element), .set(let element): element
        default: self
        }
    }
}
