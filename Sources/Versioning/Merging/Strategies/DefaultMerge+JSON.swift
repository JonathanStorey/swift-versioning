// MARK: - DefaultMerge for JSON

extension DefaultMerge where Value == JSONRepresentation {
    /// Merges JSON of the shape `schema` describes, or of the shape inferred
    /// from the three versions when it is `nil`.
    ///
    /// Inferring finds objects and arrays of objects with an `"id"`, but
    /// cannot tell a set from an array or an optional property from a
    /// removed one.
    public init(favoring: KeepMerge<JSONRepresentation>? = nil, using schema: JSONSchema?) {
        self.init(favoring: favoring)
        json = JSONMerge(schema: schema)
    }

    /// Merges the JSON of `type`, guided by its schema. Each `Codable`
    /// ``Mergeable`` value inside it, `type` included, merges by its own rules,
    /// and each array of `Identifiable` elements merges by `id`.
    ///
    /// Only what conflicts is decoded, so JSON that `type` cannot read, such
    /// as a newer version's, still merges. A type ``JSONSchema/init(for:)``
    /// cannot describe merges by the inferred shape instead.
    public init<T: Decodable>(favoring: KeepMerge<JSONRepresentation>? = nil, for type: T.Type) {
        self.init(favoring: favoring)
        if let recorded = try? JSONSchema.recording(type) {
            json = JSONMerge(schema: recorded.schema, mergeables: recorded.mergeables, identifiers: recorded.identifiers)
        }
    }
}

// MARK: - Engine

/// What guides a merge of JSON: the schema, the type of each `Mergeable`
/// value and where each `Identifiable` element keeps its `id`, each by its
/// path in the schema, where an array's element is at index 0 and a
/// dictionary's value at key `"*"`.
///
/// A metatype holds no state, and a `Mergeable` merge is a function of its
/// arguments, so sharing them across threads is safe.
struct JSONMerge: @unchecked Sendable {
    var schema: JSONSchema?
    var mergeables: [JSONRepresentation.Path: any (Mergeable & Codable).Type] = [:]
    var identifiers: [JSONRepresentation.Path: JSONRepresentation.Path] = [:]
}

extension JSONMerge {
    /// The merge, with every conflict settled by `favoring`, or holding ours when it is `nil`.
    func merged(
        _ ours: JSONRepresentation,
        _ theirs: JSONRepresentation,
        base: JSONRepresentation?,
        favoring: KeepMerge<JSONRepresentation>?
    ) -> (merged: JSONRepresentation, conflicts: [JSONRepresentation.Path]) {
        var merge = self
        if merge.schema == nil { merge.schema = JSONSchema(inferredFrom: [ours, theirs] + (base.map { [$0] } ?? [])) }
        var (merged, conflicts) = merge.mergedByShape(ours, theirs, base: base, favoring: favoring)
        guard !mergeables.isEmpty else { return (merged, conflicts) }
        var settled: [JSONRepresentation.Path] = []
        merged = merge.settling(merged, ours, theirs, base: base, isTwoWay: base == nil, under: merge.schema, at: [], [], settled: &settled)
        conflicts.removeAll { conflict in settled.contains { conflict.starts(with: $0) } }
        return (merged, conflicts)
    }
}

// MARK: Merging by shape

private extension JSONMerge {
    /// The merge of JSON alone: by schema, then by `id` where an array of
    /// identified elements conflicts, then by `favoring`.
    func mergedByShape(
        _ ours: JSONRepresentation,
        _ theirs: JSONRepresentation,
        base: JSONRepresentation?,
        favoring: KeepMerge<JSONRepresentation>?
    ) -> (merged: JSONRepresentation, conflicts: [JSONRepresentation.Path]) {
        guard let schema else { return (ours, ours == theirs ? [] : [[]]) }
        let result = ours.merging(theirs, base: base, under: schema)
        var merged = result.merged
        var conflicts: [JSONRepresentation.Path] = []
        for path in result.conflicts {
            let elementPath = schema.spelling(of: path) + [.index(0)]
            if case .array(let element)? = schema.schema(at: path)?.unwrapped, let idPath = idPath(at: elementPath, element: element),
               case .array(let mine)? = ours[path], case .array(let yours)? = theirs[path],
               let result = rooted(at: elementPath, schema: element).mergedByID(mine, yours, base: base?[path]?.elements, by: idPath, favoring: favoring) {
                merged[path] = .array(result.merged)
                conflicts += result.conflicts.map { path + $0 }
            } else {
                if case .theirs? = favoring { merged[path] = theirs[path] }
                conflicts.append(path)
            }
        }
        return (merged, conflicts)
    }

    /// Arrays merged by the `id` at `idPath` in each element, in ours's order
    /// with elements only theirs has at the end, or `nil` when an element has
    /// no `id`. Here `self` merges one element.
    func mergedByID(
        _ ours: [JSONRepresentation],
        _ theirs: [JSONRepresentation],
        base: [JSONRepresentation]?,
        by idPath: JSONRepresentation.Path,
        favoring: KeepMerge<JSONRepresentation>?
    ) -> (merged: [JSONRepresentation], conflicts: [JSONRepresentation.Path])? {
        guard let oursByID = ours.byID(idPath), let theirsByID = theirs.byID(idPath) else { return nil }
        let baseByID = base?.byID(idPath) ?? [:]
        let keepsTheirs = if case .theirs? = favoring { true } else { false }
        var merged: [JSONRepresentation] = []
        var conflicts: [JSONRepresentation.Path] = []

        for mine in ours {
            let original = baseByID[mine[idPath]!]
            if let yours = theirsByID[mine[idPath]!] {
                let result = mergedByShape(mine, yours, base: original, favoring: favoring)
                conflicts += result.conflicts.map { [.index(merged.count)] + $0 }
                merged.append(result.merged)
            } else if let original, mine != original {
                // Theirs removed what ours changed.
                conflicts.append([.index(merged.count)])
                if !keepsTheirs { merged.append(mine) }
            } else if original == nil {
                merged.append(mine)  // Ours added it.
            }
        }
        for yours in theirs where oursByID[yours[idPath]!] == nil {
            let original = baseByID[yours[idPath]!]
            if let original, yours != original {
                // Ours removed what theirs changed.
                conflicts.append([.index(merged.count)])
                if keepsTheirs { merged.append(yours) }
            } else if original == nil {
                merged.append(yours)  // Theirs added it.
            }
        }
        return (merged, conflicts)
    }

    /// The path of the `id` in each element of the array whose element is at
    /// `elementPath`: where its `Identifiable` type encodes it, or `"id"` when
    /// the element is an object with that property.
    func idPath(at elementPath: JSONRepresentation.Path, element: JSONSchema) -> JSONRepresentation.Path? {
        if let idPath = identifiers[elementPath] { return idPath }
        guard case .object(let properties) = element.unwrapped, properties.contains(where: { $0.key == "id" }) else { return nil }
        return ["id"]
    }

    /// The guide for the value at `prefix`, described by `schema`.
    func rooted(at prefix: JSONRepresentation.Path, schema: JSONSchema) -> JSONMerge {
        var identifiers: [JSONRepresentation.Path: JSONRepresentation.Path] = [:]
        for (path, idPath) in self.identifiers where path.starts(with: prefix) {
            identifiers[JSONRepresentation.Path(Array(path.dropFirst(prefix.count)))] = idPath
        }
        return JSONMerge(schema: schema, identifiers: identifiers)
    }
}

// MARK: Mergeable values

private extension JSONMerge {
    /// `merged`, at `path`, with each `Mergeable` value both sides changed
    /// replaced by its own merge of `ours` and `theirs`. Appends the path of
    /// each value it replaced to `settled`.
    ///
    /// `schemaPath` is `path` as the schema spells it. Elements of an array
    /// pair up by `id`, or by position when no array changed its length.
    func settling(
        _ merged: JSONRepresentation,
        _ ours: JSONRepresentation,
        _ theirs: JSONRepresentation,
        base: JSONRepresentation?,
        isTwoWay: Bool,
        under schema: JSONSchema?,
        at schemaPath: JSONRepresentation.Path,
        _ path: JSONRepresentation.Path,
        settled: inout [JSONRepresentation.Path]
    ) -> JSONRepresentation {
        if let type = mergeables[schemaPath] {
            // As a typed merge does, both sides making the same change still merges, so two raises add up.
            let bothChanged = if isTwoWay {
                !ours.isEquivalent(to: theirs)
            } else if let base {
                !ours.isEquivalent(to: base) && !theirs.isEquivalent(to: base)
            } else {
                false  // Both sides added it.
            }
            guard bothChanged, let value = type.mergedJSON(ours, theirs, base: base) else { return merged }
            settled.append(path)
            return value
        }

        /// The child at `segment`, settled, when both sides have it.
        func child(
            _ value: JSONRepresentation,
            at segment: JSONRepresentation.Path.Segment,
            spelled schemaSegment: JSONRepresentation.Path.Segment,
            _ mine: JSONRepresentation?,
            _ yours: JSONRepresentation?,
            _ original: JSONRepresentation?,
            under schema: JSONSchema?,
            settled: inout [JSONRepresentation.Path]
        ) -> JSONRepresentation {
            guard let mine, let yours else { return value }
            return settling(value, mine, yours, base: original, isTwoWay: isTwoWay, under: schema, at: schemaPath + [schemaSegment], path + [segment], settled: &settled)
        }

        switch (schema?.unwrapped, merged) {
        case (.object(let properties)?, .object(let pairs)):
            var result: JSONRepresentation.Object = []
            for pair in pairs {
                let schema = properties.first { $0.key == pair.key }?.value
                let value = child(pair.value, at: .key(pair.key), spelled: .key(pair.key), ours[pair.key], theirs[pair.key], base?[pair.key], under: schema, settled: &settled)
                result.append((key: pair.key, value: value))
            }
            return .object(result)
        case (.dictionary(let values)?, .object(let pairs)):
            var result: JSONRepresentation.Object = []
            for pair in pairs {
                let value = child(pair.value, at: .key(pair.key), spelled: "*", ours[pair.key], theirs[pair.key], base?[pair.key], under: values, settled: &settled)
                result.append((key: pair.key, value: value))
            }
            return .object(result)
        case (.array(let element)?, .array(let elements)):
            let (mine, yours, originals) = (ours.elements ?? [], theirs.elements ?? [], base?.elements)
            let samePositions = mine.count == elements.count && yours.count == elements.count
                && (originals?.count ?? elements.count) == elements.count
            let idPath = idPath(at: schemaPath + [.index(0)], element: element)
            var result: [JSONRepresentation] = []
            for (index, value) in elements.enumerated() {
                if let idPath, let id = value[idPath] {
                    // An identified element pairs with the same `id` on each side, wherever it is.
                    let match = { (elements: [JSONRepresentation]?) in elements?.first { $0[idPath] == id } }
                    result.append(child(value, at: .index(index), spelled: .index(0), match(mine), match(yours), match(originals), under: element, settled: &settled))
                } else if samePositions {
                    result.append(child(value, at: .index(index), spelled: .index(0), mine[index], yours[index], originals?[index], under: element, settled: &settled))
                } else {
                    result.append(value)
                }
            }
            return .array(result)
        default:
            return merged
        }
    }
}

private extension Mergeable where Self: Codable {
    /// `ours` merged with `theirs` by this type's own merge, or `nil` when a
    /// version does not decode or the merge conflicts.
    static func mergedJSON(_ ours: JSONRepresentation, _ theirs: JSONRepresentation, base: JSONRepresentation?) -> JSONRepresentation? {
        guard let mine = ours.decoded(Self.self), let yours = theirs.decoded(Self.self) else { return nil }
        let original: Self?
        if let base {
            guard let value = base.decoded(Self.self) else { return nil }
            original = value
        } else {
            original = nil
        }
        guard let merged = try? merged(mine, yours, base: original) else { return nil }
        return try? JSONRepresentation(merged)
    }
}

// MARK: - Helpers

private extension JSONRepresentation.Path {
    static func + (lhs: Self, rhs: Self) -> Self {
        var path = lhs
        path.append(contentsOf: rhs)
        return path
    }
}

private extension JSONRepresentation {
    var elements: [JSONRepresentation]? {
        if case .array(let elements) = self { elements } else { nil }
    }
}

private extension [JSONRepresentation] {
    /// Each element keyed by the `id` at `idPath`, keeping the first of any
    /// repeated id, or `nil` when one has no `id`.
    func byID(_ idPath: JSONRepresentation.Path) -> [JSONRepresentation: JSONRepresentation]? {
        var result: [JSONRepresentation: JSONRepresentation] = [:]
        for element in self {
            guard let id = element[idPath] else { return nil }
            if result[id] == nil { result[id] = element }
        }
        return result
    }
}

private extension JSONSchema {
    /// The schema of the value at `path`, or `nil` when the schema does not describe it.
    func schema(at path: JSONRepresentation.Path) -> JSONSchema? {
        var current: JSONSchema? = self
        for segment in path {
            current = switch (current?.unwrapped, segment) {
            case (.object(let properties)?, .key(let key)): properties.first { $0.key == key }?.value
            case (.dictionary(let value)?, .key): value
            case (.array(let element)?, .index), (.set(let element)?, .index): element
            default: nil
            }
        }
        return current
    }

    /// `path` as the schema spells it: each array index as 0 and each
    /// dictionary key as `"*"`.
    func spelling(of path: JSONRepresentation.Path) -> JSONRepresentation.Path {
        var current: JSONSchema? = self
        var spelled: JSONRepresentation.Path = []
        for segment in path {
            switch (current?.unwrapped, segment) {
            case (.object(let properties)?, .key(let key)):
                spelled.append(segment)
                current = properties.first { $0.key == key }?.value
            case (.dictionary(let value)?, .key):
                spelled.append("*")
                current = value
            case (.array(let element)?, .index), (.set(let element)?, .index):
                spelled.append(.index(0))
                current = element
            default:
                spelled.append(segment)
                current = nil
            }
        }
        return spelled
    }
}

extension JSONSchema {
    /// This schema without any `.optional` around it.
    var unwrapped: JSONSchema {
        if case .optional(let wrapped) = self { wrapped.unwrapped } else { self }
    }
}
