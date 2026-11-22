extension JSONRepresentation {
    /// This value, ours, merged with `theirs`, guided by `schema`, along with
    /// the path of every value the two sides changed differently.
    ///
    /// A value only one side changed keeps that side. Where both changed it:
    /// - An object merges key by key, and a `Dictionary` the same way.
    /// - A `Set` merges by membership: an element either side added is kept,
    ///   and one either side removed is dropped.
    /// - An array merges element by element, like lines. If it cannot, the
    ///   conflict is the whole array.
    /// - Anything else conflicts.
    ///
    /// At each conflicting path, `merged` holds ours, so `ours[path]`,
    /// `theirs[path]` and `base?[path]` show what each side has there. A key
    /// one side removed while the other changed it conflicts too.
    ///
    /// Without a `base`, only what both sides share merges: objects key by
    /// key where both have the key, arrays of the same length element by
    /// element, and sets with the same elements.
    ///
    /// ```swift
    /// let (merged, conflicts) = ours.merging(theirs, base: base, under: try JSONSchema(for: Note.self))
    /// ```
    public func merging(_ theirs: JSONRepresentation, base: JSONRepresentation?, under schema: JSONSchema) -> (merged: JSONRepresentation, conflicts: [Path]) {
        var conflicts: [Path] = []
        let merged = merging(theirs, base: base, under: schema, at: [], conflicts: &conflicts)
        return (merged, conflicts)
    }
}

extension JSONRepresentation {
    /// Merges as the public `merging(_:base:under:)` does. A `nil` schema,
    /// such as for a key the schema does not declare, merges objects key by
    /// key and arrays element by element.
    func merging(_ theirs: JSONRepresentation, base: JSONRepresentation?, under schema: JSONSchema?, at path: Path, conflicts: inout [Path]) -> JSONRepresentation {
        // Changes are found by value, including in keys the schema does not
        // declare, so neither side's changes are lost.
        if let base {
            if theirs.isEquivalent(to: base) { return self }
            if isEquivalent(to: base) { return theirs }
        }
        if isEquivalent(to: theirs) { return self }

        // An enum with associated values encodes as an object whose one key is its case.
        // When the sides hold different cases, their payloads cannot mix, so it conflicts whole.
        if case .object(let mine) = self, case .object(let yours) = theirs,
           mine.count == 1, yours.count == 1, mine[0].key != yours[0].key {
            if case .dictionary? = schema?.flattened {} else {
                conflicts.append(path)
                return self
            }
        }

        // Both sides changed it, differently.
        switch (schema?.flattened, self, theirs) {
        case (.optional(let wrapped)?, _, _) where self != .null && theirs != .null:
            return merging(theirs, base: base == JSONRepresentation.null ? nil : base, under: wrapped, at: path, conflicts: &conflicts)
        case (.object(let properties)?, .object, .object):
            return mergingKeys(theirs, base: base, at: path, conflicts: &conflicts) { key in properties.first { $0.key == key }?.value }
        case (.dictionary(let values)?, .object, .object):
            return mergingKeys(theirs, base: base, at: path, conflicts: &conflicts) { _ in values }
        case (nil, .object, .object):
            return mergingKeys(theirs, base: base, at: path, conflicts: &conflicts) { _ in nil }
        case let (.set(items)?, .array(ours), .array(theirs)):
            if let merged = Self.mergingMembers(ours, theirs, base: base, under: items) { return merged }
        case let (.array(items)?, .array(ours), .array(theirs)):
            if let merged = Self.mergingElements(ours, theirs, base: base, under: items, at: path, conflicts: &conflicts) { return merged }
        case let (nil, .array(ours), .array(theirs)):
            if let merged = Self.mergingElements(ours, theirs, base: base, under: nil, at: path, conflicts: &conflicts) { return merged }
        default:
            break
        }
        conflicts.append(path)
        return self
    }
}

private extension JSONRepresentation {
    /// Merges two objects key by key, in ours's key order with keys only
    /// theirs has at the end. A missing optional property counts as `null`.
    func mergingKeys(_ theirs: JSONRepresentation, base: JSONRepresentation?, at path: Path, conflicts: inout [Path], schemaForKey: (String) -> JSONSchema?) -> JSONRepresentation {
        guard case .object(let ours) = self, case .object(let other) = theirs else { return self }
        var keys = ours.map { $0.key }
        keys += other.map { $0.key }.filter { !keys.contains($0) }
        var merged: Object = []
        for key in keys {
            let schema = schemaForKey(key)
            let missing: JSONRepresentation? = schema?.isOptional == true ? .null : nil
            let (mine, yours) = (self[key], theirs[key])
            let (lhs, rhs) = (mine ?? missing, yours ?? missing)
            var keyPath = path
            keyPath.append(.key(key))
            let value: JSONRepresentation?
            if let base {
                let original = base[key] ?? missing
                if rhs.isEquivalent(to: original) {
                    value = mine
                } else if lhs.isEquivalent(to: original) {
                    value = yours
                } else if let lhs, let rhs {
                    value = lhs.merging(rhs, base: original, under: schema, at: keyPath, conflicts: &conflicts)
                } else {
                    conflicts.append(keyPath)
                    value = mine
                }
            } else if let lhs, let rhs {
                value = lhs.merging(rhs, base: nil, under: schema, at: keyPath, conflicts: &conflicts)
            } else {
                conflicts.append(keyPath)
                value = mine
            }
            if let value { merged.append((key: key, value: value)) }
        }
        return .object(merged)
    }

    /// Merges two sets by membership, matching elements by equivalence, or
    /// `nil` when they cannot merge.
    static func mergingMembers(_ ours: [JSONRepresentation], _ theirs: [JSONRepresentation], base: JSONRepresentation?, under items: JSONSchema) -> JSONRepresentation? {
        func contains(_ elements: [JSONRepresentation], _ element: JSONRepresentation) -> Bool {
            elements.contains { $0.isEquivalent(to: element, under: items) }
        }
        guard case .array(let base)? = base else {
            let same = ours.count == theirs.count && ours.allSatisfy { contains(theirs, $0) }
            return same ? .array(ours) : nil
        }
        let kept = ours.filter { contains(theirs, $0) || !contains(base, $0) }
        let added = theirs.filter { !contains(ours, $0) && !contains(base, $0) }
        return .array(kept + added)
    }

    /// Merges two arrays element by element, or `nil` when they cannot
    /// merge. With a base, an element both sides replaced merges by its
    /// shape. Without one, arrays of the same length merge position by
    /// position.
    static func mergingElements(_ ours: [JSONRepresentation], _ theirs: [JSONRepresentation], base: JSONRepresentation?, under items: JSONSchema?, at path: Path, conflicts: inout [Path]) -> JSONRepresentation? {
        guard case .array(let base)? = base else {
            guard ours.count == theirs.count else { return nil }
            var merged: [JSONRepresentation] = []
            for index in ours.indices {
                var elementPath = path
                elementPath.append(.index(index))
                merged.append(ours[index].merging(theirs[index], base: nil, under: items, at: elementPath, conflicts: &conflicts))
            }
            return .array(merged)
        }
        let merged = try? ours.mergingElements(with: theirs, from: base) { ours, theirs, base throws(MergeConflict) in
            var inner: [Path] = []
            let element = ours.merging(theirs, base: base, under: items, at: [], conflicts: &inner)
            guard inner.isEmpty else { throw MergeConflict() }
            return element
        }
        return merged.map { .array($0) }
    }
}

private extension Optional<JSONRepresentation> {
    /// Whether both are missing, or both are present and equivalent.
    func isEquivalent(to other: JSONRepresentation?) -> Bool {
        switch (self, other) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.isEquivalent(to: rhs)
        default: false
        }
    }
}
