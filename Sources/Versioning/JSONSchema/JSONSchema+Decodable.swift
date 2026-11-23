import Foundation

extension JSONSchema {
    /// Describes `type` by running its `init(from:)` against a decoder that
    /// records what it asks for instead of reading data.
    ///
    /// Keys, nesting and optionality come from the type's own `Decodable`
    /// conformance, so custom `CodingKeys` are respected and the schema
    /// matches what `JSONDecoder` accepts. `decodeIfPresent` records an
    /// optional property.
    ///
    /// The schema describes what a default `JSONEncoder()` writes, so a type
    /// has exactly one schema. Encoder strategies such as
    /// `.convertToSnakeCase` or `.iso8601` are not reflected. Declare wire
    /// names with `CodingKeys` instead, which the schema respects.
    ///
    /// - `Date` and `Decimal` record `.number`, and `URL`, `Data` and `UUID`
    ///   record `.string` with a ``Format``, matching `JSONEncoder`'s
    ///   default strategies.
    /// - A fixed-width integer narrower than 64 bits records its bounds, and
    ///   an unsigned one records a minimum of 0.
    /// - A `Set` records ``set(_:)``, and a `Dictionary` keyed by `String`
    ///   records ``dictionary(_:)``.
    /// - A `CaseIterable` raw-value enum records its raw values as the only
    ///   allowed values, for example `.string(cases: ["red", "green"])`.
    ///   A raw-value enum whose placeholder (`""` or `0`) is not a case must
    ///   conform to `CaseIterable`.
    /// - Throws `DecodingError.dataCorrupted` for what `JSONSchema` cannot
    ///   describe: recursive types, other objects that read their keys at
    ///   runtime, and arrays decoded by position. An error the type throws
    ///   itself is wrapped as the `underlyingError` of a `.dataCorrupted`, so
    ///   every failure is a `DecodingError`.
    public init<T: Decodable>(for type: T.Type) throws {
        let recorder = SchemaRecorder(codingPath: [], context: SchemaRecorder.Context())
        _ = try recorder.decode(type)
        self = try recorder.schema()
    }

    /// Decodes `type` as `init(for:)` does and returns the placeholder value,
    /// with the coding path of each value in it that can be told apart.
    ///
    /// Reading a key path on the placeholder and looking up what it returns
    /// finds the coding path the property is decoded from, without runtime
    /// names, so custom `CodingKeys` are respected:
    ///
    /// ```swift
    /// let recorded = try JSONSchema.placeholder(for: Note.self)
    /// recorded.scalars[try JSONRepresentation(recorded.value.address.city)]   // ["address", "city"]
    /// ```
    ///
    /// - Each `String`, number, `Date`, `Decimal`, `UUID`, `URL` and `Data` is
    ///   unique, and `scalars` holds its path by its JSON. An array's element
    ///   is at index 0, so the path's `description` reads like `$.stops[0].city`. A `Bool` has
    ///   too few values to be unique, so it is not listed, and neither is a
    ///   fixed-width integer too narrow for its unique number.
    /// - A value that rejects its unique placeholder, such as a raw-value enum
    ///   or a type that validates its text, is decoded again with the plain
    ///   placeholders `init(for:)` uses, so nothing inside it is listed.
    /// - Each ``Markable`` value is given its own marker, and `markers` holds
    ///   its coding path by its marker.
    public static func placeholder<T: Decodable>(for type: T.Type) throws -> (value: T, markers: [UUID: [String]], scalars: [JSONRepresentation: JSONRepresentation.Path]) {
        let context = SchemaRecorder.Context()
        context.usesUniqueScalars = true
        let value = try SchemaRecorder(codingPath: [], context: context).decode(type)
        return (value, context.markers, context.scalars)
    }

    /// A value that ``placeholder(for:)`` gives a unique marker.
    public protocol Markable {
        /// Stores `marker` so it can be read back from the placeholder.
        mutating func mark(_ marker: UUID)
    }
}

// MARK: - Recorder

/// A `Decoder` that records the schema of one value position. Containers
/// create child recorders for properties and array elements, and
/// `schema()` assembles the tree once decoding finishes.
private final class SchemaRecorder: Decoder {
    final class Context {
        /// Types being recorded on the current path, to detect recursion.
        var visiting: Set<ObjectIdentifier> = []
        /// The coding path of each marker handed to a ``JSONSchema/Markable``
        /// value, so a key path read from the placeholder finds its coding path.
        var markers: [UUID: [String]] = [:]
        /// Whether each scalar gets a unique placeholder, for ``JSONSchema/placeholder(for:)``.
        var usesUniqueScalars = false
        /// The last number handed out for a unique scalar.
        var uniqueCount = 0
        /// The path of each unique scalar, by its JSON.
        var scalars: [JSONRepresentation: JSONRepresentation.Path] = [:]
    }

    enum Kind {
        case unknown
        case scalar(JSONSchema)
        case object([(key: String, recorder: SchemaRecorder)], readsAllKeys: Bool)
        case array(SchemaRecorder?)
        case dictionary(SchemaRecorder)
    }

    let codingPath: [any CodingKey]
    let context: Context
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    var kind: Kind = .unknown
    var isOptional = false
    /// Whether the array's elements are unique, as a `Set`'s are.
    var isUnique = false
    /// Keys checked with `contains(_:)`. A type that checks for a key before
    /// decoding it treats the key as optional.
    var checkedKeys: Set<String> = []

    init(codingPath: [any CodingKey], context: Context) {
        self.codingPath = codingPath
        self.context = context
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        try beginObject()
        return KeyedDecodingContainer(KeyedRecorder<Key>(recorder: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try beginArray()
        return UnkeyedRecorder(recorder: self)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueRecorder(recorder: self)
    }
}

extension SchemaRecorder {
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let path = codingPath.map(\.stringValue)
        if let value = try foundationPlaceholder(type) { return value }
        if let dictionary = type as? any StringKeyedDictionary.Type {
            _ = try values().decode(dictionary.valueType)
            guard let value = dictionary.init() as? T else { preconditionFailure("\(T.self) is the dictionary type") }
            return value
        }

        let id = ObjectIdentifier(type)
        guard context.visiting.insert(id).inserted else {
            throw unsupported("\(T.self) contains itself. JSONSchema has no references, so it cannot describe a recursive type.")
        }
        defer { context.visiting.remove(id) }

        let value: T
        do {
            value = try construct(type)
        } catch where context.usesUniqueScalars {
            // A type that rejects a unique placeholder gets the plain ones.
            context.usesUniqueScalars = false
            defer { context.usesUniqueScalars = true }
            value = try construct(type)
        }
        recordCases(of: type)
        if case .array = kind, type is any SetAlgebra.Type {
            isUnique = true
        }
        // A markable value gets a unique marker, so a key path can find it.
        if let markable = value as? any JSONSchema.Markable {
            let marker = UUID()
            context.markers[marker] = path
            return markable.marked(marker) as? T ?? value
        }
        return value
    }

    /// Runs `type`'s own `init(from:)` against this recorder.
    func construct<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try T(from: self)
        } catch {
            // A raw-value enum records its raw type, then rejects the
            // placeholder. A CaseIterable enum supplies a real case instead.
            guard case .scalar = kind else {
                // Every failure is a `DecodingError`, as with `JSONDecoder`.
                throw error as? DecodingError ?? .dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(T.self) threw an error while being recorded.", underlyingError: error))
            }
            guard let first = firstCase(of: type) else {
                throw unsupported("\(T.self) rejected the recorder's placeholder value (an empty string, zero or false). A raw-value enum can conform to CaseIterable to supply a real case. Other types that validate their decoded value cannot be recorded.")
            }
            return first
        }
    }

    /// Narrows a recorded `.string()` or `.integer()` to the raw values of a
    /// `CaseIterable` raw-value enum.
    func recordCases<T>(of type: T.Type) {
        guard case .scalar(let schema) = kind, let rawValues = rawValues(of: type) else { return }
        switch schema {
        case .string(nil, nil):
            let strings = rawValues.compactMap { $0 as? String }
            if strings.count == rawValues.count {
                kind = .scalar(.string(cases: Set(strings)))
            }
        case .integer(nil, _, _):
            let integers = rawValues.compactMap { ($0 as? any BinaryInteger).flatMap { Int64(exactly: $0) } }
            if integers.count == rawValues.count {
                kind = .scalar(.integer(cases: Set(integers)))
            }
        default:
            break
        }
    }

    func scalar<T>(_ schema: JSONSchema, _ placeholder: T) throws -> T {
        switch kind {
        case .unknown:
            kind = .scalar(schema)
        case .scalar(let existing) where existing == schema:
            break
        default:
            throw unsupported("The value was decoded as more than one kind.")
        }
        guard context.usesUniqueScalars, let unique = unique(like: placeholder),
              let encodable = unique as? any Encodable, let json = try? JSONRepresentation(encodable) else { return placeholder }
        context.scalars[json] = JSONRepresentation.Path(codingPath.map { $0 as? JSONRepresentation.Path.Segment ?? .key($0.stringValue) })
        return unique
    }

    /// A value of `placeholder`'s type made from the next unique number, or `nil` for a type
    /// with too few values.
    func unique<T>(like placeholder: T) -> T? {
        context.uniqueCount += 1
        let number = context.uniqueCount
        let value: Any? = switch placeholder {
        case is String: String(number)
        case is Double: Double(number)
        case is Float: Float(number)
        case let integer as any FixedWidthInteger: integer.exactly(number)
        case is Date: Date(timeIntervalSinceReferenceDate: Double(number))
        case is Decimal: Decimal(number)
        case is UUID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", number))
        case is URL: URL(fileURLWithPath: "/\(number)")
        case is Data: Data(String(number).utf8)
        default: nil
        }
        return value as? T
    }

    func child(for key: any CodingKey) throws -> SchemaRecorder {
        try beginObject()
        guard case .object(var properties, let readsAllKeys) = kind else { preconditionFailure("beginObject() sets .object") }
        if let existing = properties.first(where: { $0.key == key.stringValue }) {
            return existing.recorder
        }
        let child = SchemaRecorder(codingPath: codingPath + [key], context: context)
        properties.append((key: key.stringValue, recorder: child))
        kind = .object(properties, readsAllKeys: readsAllKeys)
        return child
    }

    func element() throws -> SchemaRecorder {
        try beginArray()
        if case .array(let element?) = kind { return element }
        let element = SchemaRecorder(codingPath: codingPath + [JSONRepresentation.Path.Segment.index(0)], context: context)
        kind = .array(element)
        return element
    }

    /// The recorder for a dictionary's values, whose path ends in `"*"`.
    func values() throws -> SchemaRecorder {
        switch kind {
        case .unknown:
            let values = SchemaRecorder(codingPath: codingPath + [JSONRepresentation.Path.Segment.key("*")], context: context)
            kind = .dictionary(values)
            return values
        case .dictionary(let values):
            return values
        default:
            throw unsupported("The value was decoded as more than one kind.")
        }
    }

    func readAllKeys() {
        if case .object(let properties, _) = kind {
            kind = .object(properties, readsAllKeys: true)
        }
    }

    func schema() throws -> JSONSchema {
        let base: JSONSchema
        switch kind {
        case .unknown:
            throw unsupported("Nothing was decoded, so there is no schema to record.")
        case .scalar(let schema):
            base = schema
        case .object(let properties, let readsAllKeys):
            guard !readsAllKeys else {
                throw unsupported("The keys are read at runtime. JSONSchema describes a Dictionary keyed by String, but not other types that read their keys at runtime.")
            }
            base = .object(try properties.map { property in
                let schema = try property.recorder.schema()
                let isChecked = checkedKeys.contains(property.key) && !schema.isOptional
                return (key: property.key, value: isChecked ? .optional(schema) : schema)
            })
        case .array(let element):
            guard let element else { throw unsupported("No array element was decoded.") }
            base = isUnique ? .set(try element.schema()) : .array(try element.schema())
        case .dictionary(let values):
            base = .dictionary(try values.schema())
        }
        return isOptional ? .optional(base) : base
    }

    func unsupported(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: message))
    }
}

private extension SchemaRecorder {
    func beginObject() throws {
        switch kind {
        case .unknown: kind = .object([], readsAllKeys: false)
        case .object: break
        default: throw unsupported("The value was decoded as more than one kind.")
        }
    }

    func beginArray() throws {
        switch kind {
        case .unknown: kind = .array(nil)
        case .array: break
        default: throw unsupported("The value was decoded as more than one kind.")
        }
    }

    /// Foundation types whose own `Decodable` conformance does not match
    /// what `JSONEncoder` writes by default, or rejects a placeholder value.
    func foundationPlaceholder<T>(_ type: T.Type) throws -> T? {
        switch type {
        case is Date.Type: return try scalar(.number, Date(timeIntervalSinceReferenceDate: 0) as? T)
        case is Decimal.Type: return try scalar(.number, Decimal() as? T)
        case is URL.Type: return try scalar(.string(format: .uriReference), URL(fileURLWithPath: "/") as? T)
        case is Data.Type: return try scalar(.string(format: .base64), Data() as? T)
        case is UUID.Type: return try scalar(.string(format: .uuid), UUID() as? T)
        default: return nil
        }
    }
}

/// A dictionary keyed by `String`, which `JSONEncoder` writes as an object
/// with any keys.
private protocol StringKeyedDictionary {
    static var valueType: any Decodable.Type { get }
    init()
}

extension Dictionary: StringKeyedDictionary where Key == String, Value: Decodable {
    static var valueType: any Decodable.Type { Value.self }
}

private extension JSONSchema {
    /// The schema of a fixed-width integer. `Int` and `UInt` follow `Int64`
    /// and `UInt64` on every platform, so a schema does not depend on where
    /// it was made, and 64-bit types have no upper bound.
    static func integer<T: FixedWidthInteger>(for type: T.Type) -> JSONSchema {
        guard T.bitWidth < 64, T.self != Int.self, T.self != UInt.self else {
            return .integer(minimum: T.isSigned ? nil : 0)
        }
        return .integer(minimum: Int64(T.min), maximum: Int64(T.max))
    }
}

private func firstCase<T>(of type: T.Type) -> T? {
    guard let caseIterable = type as? any CaseIterable.Type else { return nil }
    return firstCase(in: caseIterable) as? T
}

private func firstCase<C: CaseIterable>(in type: C.Type) -> C? {
    type.allCases.first
}

private func rawValues<T>(of type: T.Type) -> [Any]? {
    guard let enumType = type as? any (CaseIterable & RawRepresentable).Type else { return nil }
    return rawValues(in: enumType)
}

private func rawValues<C: CaseIterable & RawRepresentable>(in type: C.Type) -> [Any] {
    type.allCases.map { $0.rawValue }
}

// MARK: - Containers

private struct KeyedRecorder<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let recorder: SchemaRecorder

    var codingPath: [any CodingKey] { recorder.codingPath }

    var allKeys: [Key] {
        recorder.readAllKeys()
        return []
    }

    /// Reports every key as present so its type is still recorded, and
    /// remembers the check so the property is recorded as optional.
    func contains(_ key: Key) -> Bool {
        recorder.checkedKeys.insert(key.stringValue)
        return true
    }

    /// Called by `decodeIfPresent` before it decodes. Marks the property
    /// optional and reports a value so the wrapped type is still recorded.
    func decodeNil(forKey key: Key) throws -> Bool {
        try recorder.child(for: key).isOptional = true
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try recorder.child(for: key).scalar(.boolean, false) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try recorder.child(for: key).scalar(.string(), "") }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try recorder.child(for: key).scalar(.number, 0) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try recorder.child(for: key).scalar(.number, 0) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try recorder.child(for: key).scalar(.integer(for: type), 0) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try recorder.child(for: key).scalar(.integer(for: type), 0) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try recorder.child(for: key).scalar(.integer(for: type), 0) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try recorder.child(for: key).scalar(.integer(for: type), 0) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try recorder.child(for: key).scalar(.integer(for: type), 0) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try recorder.child(for: key).scalar(.integer(for: type), 0) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try recorder.child(for: key).scalar(.integer(for: type), 0) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try recorder.child(for: key).scalar(.integer(for: type), 0) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try recorder.child(for: key).scalar(.integer(for: type), 0) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try recorder.child(for: key).scalar(.integer(for: type), 0) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try recorder.child(for: key).decode(type)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try recorder.child(for: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try recorder.child(for: key).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        try recorder.child(for: JSONRepresentation.Path.Segment.key("super"))
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        try recorder.child(for: key)
    }
}

/// Reports exactly one element, so `Array` and `Set` decode one element and
/// its type is recorded. A second positional decode is unsupported.
private struct UnkeyedRecorder: UnkeyedDecodingContainer {
    let recorder: SchemaRecorder
    private(set) var currentIndex = 0

    var codingPath: [any CodingKey] { recorder.codingPath }
    var count: Int? { nil }
    var isAtEnd: Bool { currentIndex > 0 }

    private mutating func nextElement() throws -> SchemaRecorder {
        guard currentIndex == 0 else {
            throw recorder.unsupported("The array is decoded by position. JSONSchema arrays have a single element type.")
        }
        currentIndex += 1
        return try recorder.element()
    }

    mutating func decodeNil() throws -> Bool {
        try recorder.element().isOptional = true
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try nextElement().scalar(.boolean, false) }
    mutating func decode(_ type: String.Type) throws -> String { try nextElement().scalar(.string(), "") }
    mutating func decode(_ type: Double.Type) throws -> Double { try nextElement().scalar(.number, 0) }
    mutating func decode(_ type: Float.Type) throws -> Float { try nextElement().scalar(.number, 0) }
    mutating func decode(_ type: Int.Type) throws -> Int { try nextElement().scalar(.integer(for: type), 0) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try nextElement().scalar(.integer(for: type), 0) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try nextElement().scalar(.integer(for: type), 0) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try nextElement().scalar(.integer(for: type), 0) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try nextElement().scalar(.integer(for: type), 0) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try nextElement().scalar(.integer(for: type), 0) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try nextElement().scalar(.integer(for: type), 0) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try nextElement().scalar(.integer(for: type), 0) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try nextElement().scalar(.integer(for: type), 0) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try nextElement().scalar(.integer(for: type), 0) }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try nextElement().decode(type)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try nextElement().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try nextElement().unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        try nextElement()
    }
}

private struct SingleValueRecorder: SingleValueDecodingContainer {
    let recorder: SchemaRecorder

    var codingPath: [any CodingKey] { recorder.codingPath }

    /// Called by `Optional.init(from:)`. Marks the value optional and reports
    /// a value so the wrapped type is still recorded.
    func decodeNil() -> Bool {
        recorder.isOptional = true
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool { try recorder.scalar(.boolean, false) }
    func decode(_ type: String.Type) throws -> String { try recorder.scalar(.string(), "") }
    func decode(_ type: Double.Type) throws -> Double { try recorder.scalar(.number, 0) }
    func decode(_ type: Float.Type) throws -> Float { try recorder.scalar(.number, 0) }
    func decode(_ type: Int.Type) throws -> Int { try recorder.scalar(.integer(for: type), 0) }
    func decode(_ type: Int8.Type) throws -> Int8 { try recorder.scalar(.integer(for: type), 0) }
    func decode(_ type: Int16.Type) throws -> Int16 { try recorder.scalar(.integer(for: type), 0) }
    func decode(_ type: Int32.Type) throws -> Int32 { try recorder.scalar(.integer(for: type), 0) }
    func decode(_ type: Int64.Type) throws -> Int64 { try recorder.scalar(.integer(for: type), 0) }
    func decode(_ type: UInt.Type) throws -> UInt { try recorder.scalar(.integer(for: type), 0) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try recorder.scalar(.integer(for: type), 0) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try recorder.scalar(.integer(for: type), 0) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try recorder.scalar(.integer(for: type), 0) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try recorder.scalar(.integer(for: type), 0) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try recorder.decode(type)
    }
}

private extension JSONSchema.Markable {
    func marked(_ marker: UUID) -> Self {
        var copy = self
        copy.mark(marker)
        return copy
    }
}

private extension FixedWidthInteger {
    /// `number` as this type, or `nil` when it does not fit.
    func exactly(_ number: Int) -> Self? {
        Self(exactly: number)
    }
}
