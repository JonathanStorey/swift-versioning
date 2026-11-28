/// A type that merges with another version of itself.
///
/// A `Codable` type conforms with nothing to write: it merges field by
/// field, as ``DefaultMerge`` does. Any type can
/// implement the merge with a strategy instead, or by hand.
///
/// ```swift
/// struct Note: Codable, Mergeable {}
///
/// struct Views: RawRepresentable, Codable, Mergeable {
///     var rawValue: Int
///     func merging(with theirs: Views, from base: Views) throws(MergeConflict) -> Views {
///         try merging(with: theirs, from: base, using: .rawValue(.sum()))
///     }
/// }
///
/// let merged = try ours.merging(with: theirs, from: base)
/// let favoringTheirs = try ours.merging(with: theirs, from: base, using: .default(favoring: .theirs))
/// ```
public protocol Mergeable {
    /// This version merged with `theirs`, knowing their common ancestor.
    func merging(with theirs: Self, from base: Self) throws(MergeConflict) -> Self
    /// This version merged with `theirs`, without a common ancestor.
    func merging(with theirs: Self) throws(MergeConflict) -> Self
}

extension Mergeable {
    /// Without a base, the versions conflict.
    public func merging(with theirs: Self) throws(MergeConflict) -> Self {
        throw MergeConflict()
    }

    /// This version merged with `theirs` by `strategy`, knowing their common
    /// ancestor, in place of the type's own merge.
    public func merging(with theirs: Self, from base: Self, using strategy: some MergeStrategy<Self>) throws(MergeConflict) -> Self {
        try strategy.merge(base: base, ours: self, theirs: theirs)
    }

    /// This version merged with `theirs` by `strategy`, without a common
    /// ancestor, in place of the type's own merge.
    public func merging(with theirs: Self, using strategy: some MergeStrategy<Self>) throws(MergeConflict) -> Self {
        try strategy.merge(ours: self, theirs: theirs)
    }

    /// Merges `theirs` into this version, knowing their common ancestor. On a
    /// conflict, this version is left unchanged.
    public mutating func merge(with theirs: Self, from base: Self) throws(MergeConflict) {
        self = try merging(with: theirs, from: base)
    }

    /// Merges `theirs` into this version without a common ancestor. On a
    /// conflict, this version is left unchanged.
    public mutating func merge(with theirs: Self) throws(MergeConflict) {
        self = try merging(with: theirs)
    }
}

extension Mergeable where Self: Equatable {
    /// Without a base, equal versions merge, and any others conflict.
    public func merging(with theirs: Self) throws(MergeConflict) -> Self {
        guard self == theirs else { throw MergeConflict() }
        return self
    }
}

extension Mergeable where Self: Codable {
    /// Merges field by field, as ``DefaultMerge`` does.
    public func merging(with theirs: Self, from base: Self) throws(MergeConflict) -> Self {
        try merging(with: theirs, from: base, using: DefaultMerge())
    }

    /// Without a base, only what both versions share merges, as
    /// ``DefaultMerge`` does.
    public func merging(with theirs: Self) throws(MergeConflict) -> Self {
        try merging(with: theirs, using: DefaultMerge())
    }
}

extension Mergeable where Self: Codable & Equatable {
    /// Without a base, only what both versions share merges, as
    /// ``DefaultMerge`` does.
    public func merging(with theirs: Self) throws(MergeConflict) -> Self {
        try merging(with: theirs, using: DefaultMerge())
    }
}
