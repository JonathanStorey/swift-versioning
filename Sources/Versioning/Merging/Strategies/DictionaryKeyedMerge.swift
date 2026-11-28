/// Merges a dictionary key by key, whatever the key's type.
///
/// - A key only one side changed, added or removed keeps that side.
/// - A value both sides changed merges by its own merge if it is
///   ``Mergeable``, otherwise as ``DefaultMerge`` does.
/// - A key one side removed and the other changed conflicts.
///
/// With `favoring`, each conflicting key takes that side, and every other
/// change from both sides still applies. Without a base, a key only one
/// side has conflicts.
///
/// ```swift
/// try DictionaryKeyedMerge<String, Views>(favoring: .theirs).merge(base: base, ours: mine, theirs: yours)
/// ```
public struct DictionaryKeyedMerge<Key: Hashable & Codable, Element: Codable>: MergeStrategy {
    public typealias Value = [Key: Element]

    /// The side kept at each conflicting key, or `nil` to throw.
    public var favoring: KeepMerge<[Key: Element]>?

    public init(favoring: KeepMerge<[Key: Element]>? = nil) {
        self.favoring = favoring
    }

    public func merge(base: [Key: Element], ours: [Key: Element], theirs: [Key: Element]) throws(MergeConflict) -> [Key: Element] {
        try merged(ours, theirs, base: base)
    }

    public func merge(ours: [Key: Element], theirs: [Key: Element]) throws(MergeConflict) -> [Key: Element] {
        try merged(ours, theirs, base: nil)
    }
}

private extension DictionaryKeyedMerge {
    func merged(_ ours: [Key: Element], _ theirs: [Key: Element], base: [Key: Element]?) throws(MergeConflict) -> [Key: Element] {
        var conflicts: [MergeConflict.Path] = []
        var merged: [Key: Element] = [:]
        for key in Set(ours.keys).union(theirs.keys) {
            let path: MergeConflict.Path = [.key(String(describing: key))]
            switch (ours[key], theirs[key]) {
            case let (mine?, other?):
                merged[key] = MergeConflict.collect(into: &conflicts, at: path) { () throws(MergeConflict) in
                    try Element.mergedElement(mine, other, base: base?[key], favoring: favoring?.retyped())
                }
            case let (mine?, nil):
                if MergeConflict.collect(into: &conflicts, at: path, { () throws(MergeConflict) in try keeps(mine, changedBy: KeepMerge<Element>.ours, base: base.map { $0[key] }) }) == true {
                    merged[key] = mine
                }
            case let (nil, other?):
                if MergeConflict.collect(into: &conflicts, at: path, { () throws(MergeConflict) in try keeps(other, changedBy: KeepMerge<Element>.theirs, base: base.map { $0[key] }) }) == true {
                    merged[key] = other
                }
            case (nil, nil):
                break
            }
        }
        // A dictionary has no order, so neither do its conflicts.
        guard conflicts.isEmpty else { throw MergeConflict(at: conflicts.sorted { $0.description < $1.description }) }
        return merged
    }

    /// Whether a value only `changer` has stays: it does if that side added
    /// it, not if the other side removed it unchanged, and by `favoring` if
    /// the other side removed what this side changed. `base` is `nil`
    /// without a base, and `.some(nil)` where the base lacks the key.
    func keeps(_ value: Element, changedBy changer: KeepMerge<Element>, base: Element??) throws(MergeConflict) -> Bool {
        if let base {
            guard let was = base else { return true }
            if value.encodesLike(was) { return false }
        }
        guard let favoring else { throw MergeConflict() }
        return favoring.keeps(changedBy: changer)
    }
}
