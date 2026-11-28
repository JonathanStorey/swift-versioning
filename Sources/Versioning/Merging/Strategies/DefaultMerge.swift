/// The best merge for a `Codable` value, and what a `Codable` ``Mergeable``
/// type uses unless it names another. It merges property by property, as
/// ``PropertyMerge`` does, but lets each property's type decide wherever
/// both sides changed it, at any depth:
///
/// - A ``Mergeable`` type merges by its own merge, so a `Views` counter sums.
/// - An array or set of `Identifiable` elements merges by `id`, as
///   ``IdentifiedElementMerge`` does.
/// - A dictionary merges by key, whatever its key type, each value by its
///   own type.
///
/// Every rule comes from something a type declares, so a type that declares
/// nothing merges exactly as ``PropertyMerge`` does. Without `favoring`, a
/// conflict that no rule settles throws. With it, each conflicting value
/// takes that side.
///
/// `DefaultMerge<JSONRepresentation>` merges JSON guided by a schema or a
/// type, and never needs to decode the whole value. See
/// ``init(favoring:for:)``.
///
/// ```swift
/// try ours.merging(with: theirs, from: base, using: .default(favoring: .theirs))
/// ```
public struct DefaultMerge<Value>: Sendable {
    /// The side kept at each conflicting value, or `nil` to throw.
    public var favoring: KeepMerge<Value>?
    /// What guides a merge of `JSONRepresentation` values.
    var json = JSONMerge()

    public init(favoring: KeepMerge<Value>? = nil) {
        self.favoring = favoring
    }
}

@available(*, deprecated, renamed: "DefaultMerge")
public typealias DefaultMergeStrategy<Value> = DefaultMerge<Value>

extension DefaultMerge: MergeStrategy where Value: Codable {
    public func merge(base: Value, ours: Value, theirs: Value) throws(MergeConflict) -> Value {
        try merged(ours, theirs, base: base)
    }

    /// Without a base, only what both sides share merges. See
    /// ``JSONRepresentation/merging(_:base:under:)``.
    public func merge(ours: Value, theirs: Value) throws(MergeConflict) -> Value {
        try merged(ours, theirs, base: nil)
    }

    /// One merge for every value: a `JSONRepresentation` merges as it is,
    /// guided by `json`, and any other value merges as its JSON, guided by
    /// its own type, then decodes. Without `favoring`, any conflict throws.
    private func merged(_ ours: Value, _ theirs: Value, base: Value?) throws(MergeConflict) -> Value {
        if let mine = ours as? JSONRepresentation, let yours = theirs as? JSONRepresentation {
            let result = json.merged(mine, yours, base: base as? JSONRepresentation, favoring: favoring?.retyped())
            if favoring == nil, !result.conflicts.isEmpty { throw MergeConflict(at: result.conflicts) }
            guard let merged = result.merged as? Value else { throw MergeConflict() }
            return merged
        }
        return try favoring.resolving(ours: ours, theirs: theirs) { () throws(MergeConflict) in
            guard let mine = try? JSONRepresentation(ours), let yours = try? JSONRepresentation(theirs) else { throw MergeConflict() }
            var original: JSONRepresentation?
            if let base {
                guard let value = try? JSONRepresentation(base) else { throw MergeConflict() }
                original = value
            }
            var guide = JSONMerge(for: Value.self)
            // A `Mergeable` type's own merge may be this one, so only the values inside it follow their rules.
            guide.rules[[]] = nil
            let result = guide.merged(mine, yours, base: original, favoring: favoring?.retyped())
            if favoring == nil, !result.conflicts.isEmpty { throw MergeConflict(at: result.conflicts) }
            guard let merged = try? result.merged.decode(Value.self) else { throw MergeConflict() }
            return merged
        }
    }
}
