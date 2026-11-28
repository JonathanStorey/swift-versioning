import Foundation

/// One merge of a `Codable` value: the three encoded versions, their merge
/// as JSON, and the paths that a property's own rules settled. Reading
/// types, decoding through it gives each property the rules of its type.
///
/// It lives for one synchronous decode, so its mutable state is never
/// shared across threads.
final class MergeContext: @unchecked Sendable {
    private let ours: JSONRepresentation
    private let theirs: JSONRepresentation
    private let base: JSONRepresentation?
    private let merged: JSONRepresentation
    private let conflicts: [JSONRepresentation.Path]
    private let side: KeepMerge<Void>?
    private let readsTypes: Bool
    private var settled: [JSONRepresentation.Path] = []
    private var failed: [JSONRepresentation.Path] = []

    /// Merges the encoded versions as JSON, keeping the `favoring` side at
    /// each conflict. Reading types, a property's type can settle a
    /// conflict by its own rules.
    init<Value: Codable>(_ ours: Value, _ theirs: Value, base: JSONRepresentation?, favoring side: KeepMerge<Value>?, readingTypes readsTypes: Bool) throws {
        let mine = try JSONRepresentation(ours)
        let other = try JSONRepresentation(theirs)
        // A type the schema cannot describe still merges by shape.
        let schema = try? JSONSchema(for: Value.self)
        var conflicts: [JSONRepresentation.Path] = []
        var merged = mine.merging(other, base: base, under: schema, at: [], conflicts: &conflicts)
        if case .theirs? = side {
            for path in conflicts { merged[path] = other[path] }
        }
        self.ours = mine
        self.theirs = other
        self.base = base
        self.merged = merged
        self.conflicts = conflicts
        self.side = side?.retyped()
        self.readsTypes = readsTypes
    }

    /// The merged value. Without a favored side, every conflict that no
    /// property's own rules settled throws, together.
    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let value = readsTypes ? try merged.decode(Root<Value>.self, userInfo: [.propertyMerge: self]).value : try merged.decode(Value.self)
        let unsettled = conflicts.filter { conflict in !settled.contains { conflict.starts(with: $0) } }
        if side == nil, !(unsettled + failed).isEmpty { throw MergeConflict(at: unsettled + failed) }
        return value
    }

    /// The versions at `path` merged by `T`'s own rules, or `nil` when `T`
    /// has none, both sides did not change it, or a side lacks it. Both
    /// sides making the same change to a `Mergeable` value still merges, so
    /// two counters raised by one each add to two. `T`'s
    /// rules are its own merge if it is `Mergeable`, a merge by key for a
    /// dictionary, or a merge by id for an array or set of `Identifiable`
    /// elements. Where those rules conflict, the JSON merge stands, and
    /// without a favored side the conflict's paths are kept to throw from
    /// `decode(_:)`.
    func mergedValue<T: Decodable>(_ type: T.Type, at path: JSONRepresentation.Path) -> T? {
        guard readsTypes, bothChanged(at: path, evenAlike: T.self is any Mergeable.Type) else { return nil }
        let side = side
        let merge: (Any, Any, Any?) throws(MergeConflict) -> Any?
        if let mergeable = T.self as? any Mergeable.Type {
            merge = { ours, theirs, base throws(MergeConflict) in try mergeable.merged(ours, theirs, base: base) }
        } else if let elements = T.self as? any IdentifiedElements.Type {
            merge = { ours, theirs, base throws(MergeConflict) in try elements.mergedByID(ours, theirs, base: base, favoring: side) }
        } else if let entries = T.self as? any KeyedEntries.Type {
            merge = { ours, theirs, base throws(MergeConflict) in try entries.mergedByKey(ours, theirs, base: base, favoring: side) }
        } else if let elements = T.self as? any IdentifiedMembers.Type {
            merge = { ours, theirs, base throws(MergeConflict) in try elements.mergedByID(ours, theirs, base: base, favoring: side) }
        } else {
            return nil
        }
        guard let mine = ours[path].flatMap({ $0.decoded(T.self) }),
              let other = theirs[path].flatMap({ $0.decoded(T.self) }) else { return nil }
        var original: T?
        if let base {
            guard let value = base[path].flatMap({ $0.decoded(T.self) }) else { return nil }
            original = value
        }
        do {
            guard let value = try merge(mine, other, original) as? T else { return nil }
            settled.append(path)
            return value
        } catch let conflict as MergeConflict {
            if side == nil { failed += conflict.inside(path).paths }
        } catch {
            if side == nil { failed.append(path) }
        }
        settled.append(path)
        return nil
    }

    /// Whether both sides changed an object at `path`, so its properties
    /// merge one by one.
    func bothChangedObject(at path: JSONRepresentation.Path) -> Bool {
        guard readsTypes, case .object? = ours[path], case .object? = theirs[path] else { return false }
        return bothChanged(at: path)
    }

    /// Whether both sides changed the value at `path`, differently, or, when
    /// `evenAlike`, in the same way.
    private func bothChanged(at path: JSONRepresentation.Path, evenAlike: Bool = false) -> Bool {
        guard let mine = ours[path], let other = theirs[path] else { return false }
        if mine.isEquivalent(to: other), !(evenAlike && base != nil) { return false }
        guard let base else { return true }
        guard let original = base[path] else { return true }
        return !mine.isEquivalent(to: original) && !other.isEquivalent(to: original)
    }
}

extension Mergeable {
    /// `ours` merged with `theirs` by this type's own merge, or `nil` when
    /// they are not this type.
    static func merged(_ ours: Any, _ theirs: Any, base: Any?) throws(MergeConflict) -> Self? {
        guard let ours = ours as? Self, let theirs = theirs as? Self else { return nil }
        guard let base else { return try ours.merging(with: theirs) }
        guard let base = base as? Self else { return nil }
        return try ours.merging(with: theirs, from: base)
    }
}

// MARK: - Elements

/// An array of `Identifiable` elements, merged by id.
private protocol IdentifiedElements {
    static func mergedByID(_ ours: Any, _ theirs: Any, base: Any?, favoring side: KeepMerge<Void>?) throws(MergeConflict) -> Self?
}

extension Array: IdentifiedElements where Element: Identifiable & Codable {
    fileprivate static func mergedByID(_ ours: Any, _ theirs: Any, base: Any?, favoring side: KeepMerge<Void>?) throws(MergeConflict) -> Self? {
        guard let ours = ours as? Self, let theirs = theirs as? Self else { return nil }
        let strategy = IdentifiedElementMerge<Element>(favoring: side?.retyped())
        guard let base else { return try strategy.merge(ours: ours, theirs: theirs) }
        guard let base = base as? Self else { return nil }
        return try strategy.merge(base: base, ours: ours, theirs: theirs)
    }
}

/// A set of `Identifiable` elements, merged by id, so an element both sides
/// edited merges rather than counting as a removal and an addition.
private protocol IdentifiedMembers {
    static func mergedByID(_ ours: Any, _ theirs: Any, base: Any?, favoring side: KeepMerge<Void>?) throws(MergeConflict) -> Self?
}

extension Set: IdentifiedMembers where Element: Identifiable & Codable {
    fileprivate static func mergedByID(_ ours: Any, _ theirs: Any, base: Any?, favoring side: KeepMerge<Void>?) throws(MergeConflict) -> Self? {
        guard let ours = ours as? Self, let theirs = theirs as? Self else { return nil }
        var original: [Element]?
        if let base {
            guard let base = base as? Self else { return nil }
            original = Array(base)
        }
        return try [Element].mergedByID(Array(ours), Array(theirs), base: original, favoring: side).map(Set.init)
    }
}

/// A dictionary, merged key by key whatever its key type, since
/// `JSONEncoder` writes a dictionary keyed by anything but a `String` or an
/// `Int` as a flat array of keys and values.
private protocol KeyedEntries {
    static func mergedByKey(_ ours: Any, _ theirs: Any, base: Any?, favoring side: KeepMerge<Void>?) throws(MergeConflict) -> Self?
}

extension Dictionary: KeyedEntries where Key: Codable, Value: Codable {
    fileprivate static func mergedByKey(_ ours: Any, _ theirs: Any, base: Any?, favoring side: KeepMerge<Void>?) throws(MergeConflict) -> Self? {
        guard let ours = ours as? Self, let theirs = theirs as? Self else { return nil }
        let strategy = DictionaryKeyedMerge<Key, Value>(favoring: side?.retyped())
        guard let base else { return try strategy.merge(ours: ours, theirs: theirs) }
        guard let base = base as? Self else { return nil }
        return try strategy.merge(base: base, ours: ours, theirs: theirs)
    }
}

extension JSONRepresentation {
    /// This value decoded as `T`, or `nil`. It is wrapped in an array, since
    /// a top-level fragment is not decodable everywhere.
    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        (try? JSONRepresentation.array([self]).decode([T].self))?.first
    }
}

private extension CodingUserInfoKey {
    static let propertyMerge = CodingUserInfoKey(rawValue: "Versioning.MergeContext")!
}

// MARK: - Decoder

/// Hands `JSONDecoder`'s decoder for the merged JSON to `Value`, wrapped so
/// that each property can merge by its own type.
private struct Root<Value: Decodable>: Decodable {
    let value: Value

    init(from decoder: any Decoder) throws {
        guard let context = decoder.userInfo[.propertyMerge] as? MergeContext else { throw MergeConflict() }
        value = try Value(from: MergingDecoder(decoder: decoder, path: [], context: context))
    }
}

private struct MergingDecoder: Decoder {
    let decoder: any Decoder
    let path: JSONRepresentation.Path
    let context: MergeContext

    var codingPath: [any CodingKey] { decoder.codingPath }
    var userInfo: [CodingUserInfoKey: Any] { decoder.userInfo }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(MergingContainer(container: try decoder.container(keyedBy: type), path: path, context: context))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try decoder.unkeyedContainer()
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        try decoder.singleValueContainer()
    }
}

/// Reads the merged JSON, except that a property both sides changed merges
/// by its own type when that type is `Mergeable`, and an object both sides
/// changed is read the same way, property by property.
private struct MergingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let container: KeyedDecodingContainer<Key>
    let path: JSONRepresentation.Path
    let context: MergeContext

    var codingPath: [any CodingKey] { container.codingPath }
    var allKeys: [Key] { container.allKeys }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        var path = path
        path.append(.key(key.stringValue))
        if let value = context.mergedValue(T.self, at: path) { return value }
        if context.bothChangedObject(at: path) {
            return try T(from: MergingDecoder(decoder: try container.superDecoder(forKey: key), path: path, context: context))
        }
        return try container.decode(T.self, forKey: key)
    }

    func contains(_ key: Key) -> Bool { container.contains(key) }
    func decodeNil(forKey key: Key) throws -> Bool { try container.decodeNil(forKey: key) }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try container.decode(type, forKey: key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try container.decode(type, forKey: key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try container.decode(type, forKey: key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try container.decode(type, forKey: key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try container.decode(type, forKey: key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try container.decode(type, forKey: key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try container.decode(type, forKey: key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try container.decode(type, forKey: key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try container.decode(type, forKey: key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try container.decode(type, forKey: key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try container.decode(type, forKey: key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try container.decode(type, forKey: key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try container.decode(type, forKey: key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try container.decode(type, forKey: key) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try container.nestedContainer(keyedBy: type, forKey: key)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try container.nestedUnkeyedContainer(forKey: key)
    }

    func superDecoder() throws -> any Decoder { try container.superDecoder() }
    func superDecoder(forKey key: Key) throws -> any Decoder { try container.superDecoder(forKey: key) }
}
