/// A merge that a type declares for its own values, applied to the JSON of
/// one value wherever both sides changed it.
///
/// A type declares one by being ``Mergeable``, an array or set of
/// `Identifiable` elements, which merge by id, or a dictionary, which merges
/// by key whatever its key type.
///
/// The closure captures only the type and calls its merge, which is a
/// function of its arguments, so sharing it across threads is safe.
struct MergeRule: @unchecked Sendable {
    /// Whether both sides making the same change still merges, as it does for
    /// a `Mergeable` counter that each side raised by one.
    let mergesAlike: Bool
    /// The merge of the three versions, or `nil` when one does not decode.
    /// A conflict takes the side, or throws without one.
    let merge: (_ ours: JSONRepresentation, _ theirs: JSONRepresentation, _ base: JSONRepresentation?, _ side: KeepMerge<Void>?) throws(MergeConflict) -> JSONRepresentation?
}

extension MergeRule {
    /// The rule `type` declares, or `nil` when it declares none.
    init?(for type: any Decodable.Type) {
        guard let codable = type as? any Codable.Type, let rule = Self.rule(for: codable) else { return nil }
        self = rule
    }

    private static func rule<T: Codable>(for type: T.Type) -> MergeRule? {
        let merge: (Any, Any, Any?, KeepMerge<Void>?) throws(MergeConflict) -> Any?
        if let mergeable = T.self as? any Mergeable.Type {
            merge = { ours, theirs, base, _ throws(MergeConflict) in try mergeable.merged(ours, theirs, base: base) }
        } else if let elements = T.self as? any IdentifiedElements.Type {
            merge = { ours, theirs, base, side throws(MergeConflict) in try elements.mergedByID(ours, theirs, base: base, favoring: side) }
        } else if let entries = T.self as? any KeyedEntries.Type {
            merge = { ours, theirs, base, side throws(MergeConflict) in try entries.mergedByKey(ours, theirs, base: base, favoring: side) }
        } else if let members = T.self as? any IdentifiedMembers.Type {
            merge = { ours, theirs, base, side throws(MergeConflict) in try members.mergedByID(ours, theirs, base: base, favoring: side) }
        } else {
            return nil
        }
        return MergeRule(mergesAlike: T.self is any Mergeable.Type) { ours, theirs, base, side throws(MergeConflict) in
            guard let mine = ours.decoded(T.self), let yours = theirs.decoded(T.self) else { return nil }
            var original: T?
            if let base {
                guard let value = base.decoded(T.self) else { return nil }
                original = value
            }
            guard let value = try merge(mine, yours, original, side) as? T else { return nil }
            return try? JSONRepresentation(value)
        }
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

extension JSONRepresentation {
    /// This value decoded as `T`, or `nil`. It is wrapped in an array, since
    /// a top-level fragment is not decodable everywhere.
    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        (try? JSONRepresentation.array([self]).decode([T].self))?.first
    }
}

// MARK: - Collections

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
protocol KeyedEntries {
    static func mergedByKey(_ ours: Any, _ theirs: Any, base: Any?, favoring side: KeepMerge<Void>?) throws(MergeConflict) -> Self?
    init()
}

extension Dictionary: KeyedEntries where Key: Codable, Value: Codable {
    static func mergedByKey(_ ours: Any, _ theirs: Any, base: Any?, favoring side: KeepMerge<Void>?) throws(MergeConflict) -> Self? {
        guard let ours = ours as? Self, let theirs = theirs as? Self else { return nil }
        let strategy = DictionaryKeyedMerge<Key, Value>(favoring: side?.retyped())
        guard let base else { return try strategy.merge(ours: ours, theirs: theirs) }
        guard let base = base as? Self else { return nil }
        return try strategy.merge(base: base, ours: ours, theirs: theirs)
    }
}
