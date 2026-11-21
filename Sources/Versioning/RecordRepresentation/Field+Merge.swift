import Foundation

extension RecordRepresentation.Field: Mergeable {
    /// The side that changed the field, or the field's own merge when both did:
    /// a location keeps the later measurement, an asset with the same bytes does
    /// not conflict, a list keeps every side's additions in place, and an
    /// encrypted value merges what it holds. Any other change on both sides conflicts.
    func merging(with theirs: Self, from base: Self) throws(MergeConflict) -> Self {
        if theirs == base || self == theirs { return self }
        if self == base { return theirs }
        switch (self, theirs, base) {
        case let (.location(ours), .location(theirs), .location(base)):
            return .location(try ours.merging(with: theirs, from: base))
        case let (.asset(ours), .asset(theirs), .asset(base)):
            return .asset(try Asset(rawValue: ours).merging(with: Asset(rawValue: theirs), from: Asset(rawValue: base)).rawValue)
        case let (.list(ours), .list(theirs), .list(base)):
            return .list(try RangeReplaceableCollectionElementMerge<[Self]>().merge(base: base, ours: ours, theirs: theirs))
        case let (.encrypted(ours), .encrypted(theirs), .encrypted(base)):
            return .encrypted(try ours.merging(with: theirs, from: base))
        default:
            throw MergeConflict()
        }
    }

    /// Without a base, equal fields merge, a location keeps the later measurement,
    /// an asset with the same bytes merges, and anything else conflicts.
    func merging(with theirs: Self) throws(MergeConflict) -> Self {
        if self == theirs { return self }
        switch (self, theirs) {
        case let (.location(ours), .location(theirs)):
            return .location(try ours.merging(with: theirs))
        case let (.asset(ours), .asset(theirs)):
            return .asset(try Asset(rawValue: ours).merging(with: Asset(rawValue: theirs)).rawValue)
        case let (.encrypted(ours), .encrypted(theirs)):
            return .encrypted(try ours.merging(with: theirs))
        default:
            throw MergeConflict()
        }
    }
}

extension Dictionary where Key == String, Value == RecordRepresentation.Field {
    /// A record's fields merged key by key with `theirs`, from `base`, with no schema.
    ///
    /// A field only one side changed, added or removed keeps that side. A field
    /// both sides changed merges by ``RecordRepresentation/Field``'s merge. The
    /// conflict names every field that could not merge, such as `["title"]`.
    func merging(with theirs: Self, from base: Self) throws(MergeConflict) -> Self {
        try DictionaryKeyedMerge().merge(base: base, ours: self, theirs: theirs)
    }
}
