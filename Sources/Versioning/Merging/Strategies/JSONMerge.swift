/// A three-way merge of JSON that never throws, guided by a schema.
///
/// It merges as ``JSONRepresentation/merging(_:base:under:)`` does: a value
/// only one side changed keeps that side, objects merge property by property,
/// dictionaries by key, sets by membership and arrays element by element. It
/// adds three things:
///
/// - An array of objects with an `"id"` property that cannot merge element by
///   element merges by `"id"` instead, so each side's additions, edits and
///   removals survive.
/// - Made for a type, each `Codable` ``Mergeable`` value inside it, at any
///   depth, merges by its own rules wherever both sides changed it, so a
///   counter both sides raised adds both changes. Only that value is decoded,
///   so this works even when the rest of the JSON is not readable as the type.
/// - Every remaining conflict takes the `favoring` side, so a merge always
///   produces a value.
///
/// It never decodes the whole value, so it merges JSON the type cannot read,
/// such as a newer version's. Without a schema, it infers one from the three
/// versions, which finds objects and arrays of identified objects but cannot
/// tell a set from an array or an optional property from a removed one.
///
/// ```swift
/// let merge = try JSONMerge(favoring: .ours, for: Note.self)
/// let (merged, conflicts) = merge.merged(ours, theirs, base: base)
/// ```
public struct JSONMerge: Sendable {
    /// The side kept wherever both sides changed a value differently.
    public var favoring: KeepMerge<JSONRepresentation>
    /// The shape of the values merged, or `nil` to infer it from them.
    public let schema: JSONSchema?
    /// The type of each `Mergeable` value, by its path in the schema.
    private let mergeables: Mergeables

    /// Merges values of the shape `schema` describes, or of the shape
    /// inferred from the values when it is `nil`.
    public init(favoring: KeepMerge<JSONRepresentation> = .ours, using schema: JSONSchema? = nil) {
        self.favoring = favoring
        self.schema = schema
        self.mergeables = Mergeables(types: [:])
    }

    /// Merges the JSON of `type`, letting each `Codable` ``Mergeable`` value
    /// in it, `type` included, merge by its own rules.
    ///
    /// - Throws: A `DecodingError` when ``JSONSchema/init(for:)`` cannot
    ///   describe `type`.
    public init<T: Decodable>(favoring: KeepMerge<JSONRepresentation> = .ours, for type: T.Type) throws {
        let recorded = try JSONSchema.recording(type)
        self.favoring = favoring
        self.schema = recorded.schema
        self.mergeables = Mergeables(types: recorded.mergeables)
    }
}

extension JSONMerge {
    /// `ours` merged with `theirs`, along with the path of every conflict,
    /// each already settled by `favoring`. A `Mergeable` value's own merge is
    /// not a conflict.
    public func merged(
        _ ours: JSONRepresentation,
        _ theirs: JSONRepresentation,
        base: JSONRepresentation?
    ) -> (merged: JSONRepresentation, conflicts: [JSONRepresentation.Path]) {
        let schema = schema ?? JSONSchema(inferredFrom: [ours, theirs] + (base.map { [$0] } ?? []))
        var (merged, conflicts) = mergedByShape(ours, theirs, base: base, under: schema)
        guard !mergeables.types.isEmpty else { return (merged, conflicts) }
        var settled: [JSONRepresentation.Path] = []
        merged = settling(merged, ours, theirs, base: base, isTwoWay: base == nil, under: schema, at: [], [], settled: &settled)
        conflicts.removeAll { conflict in settled.contains { conflict.starts(with: $0) } }
        return (merged, conflicts)
    }
}

extension JSONMerge: MergeStrategy {
    public func merge(base: JSONRepresentation, ours: JSONRepresentation, theirs: JSONRepresentation) throws(MergeConflict) -> JSONRepresentation {
        merged(ours, theirs, base: base).merged
    }

    public func merge(ours: JSONRepresentation, theirs: JSONRepresentation) throws(MergeConflict) -> JSONRepresentation {
        merged(ours, theirs, base: nil).merged
    }
}

// MARK: - Merging by shape

private extension JSONMerge {
    /// The merge of JSON alone: by schema, then by `"id"` where an array of
    /// identified objects conflicts, then by `favoring`.
    func mergedByShape(
        _ ours: JSONRepresentation,
        _ theirs: JSONRepresentation,
        base: JSONRepresentation?,
        under schema: JSONSchema
    ) -> (merged: JSONRepresentation, conflicts: [JSONRepresentation.Path]) {
        let result = ours.merging(theirs, base: base, under: schema)
        var merged = result.merged
        var conflicts: [JSONRepresentation.Path] = []
        for path in result.conflicts {
            if let element = schema.schema(at: path)?.identifiedElement,
               case .array(let mine)? = ours[path], case .array(let yours)? = theirs[path],
               let result = JSONMerge(favoring: favoring, using: element).mergedByID(mine, yours, base: base?[path]?.elements) {
                merged[path] = .array(result.merged)
                conflicts += result.conflicts.map { path + $0 }
            } else {
                if case .theirs = favoring { merged[path] = theirs[path] }
                conflicts.append(path)
            }
        }
        return (merged, conflicts)
    }

    /// Arrays of objects merged by their `"id"`, in ours's order with elements
    /// only theirs has at the end, or `nil` when any element has no `"id"`.
    /// Here `self` merges one element.
    func mergedByID(
        _ ours: [JSONRepresentation],
        _ theirs: [JSONRepresentation],
        base: [JSONRepresentation]?
    ) -> (merged: [JSONRepresentation], conflicts: [JSONRepresentation.Path])? {
        guard let oursByID = ours.byID, let theirsByID = theirs.byID, let schema else { return nil }
        let baseByID = base?.byID ?? [:]
        var merged: [JSONRepresentation] = []
        var conflicts: [JSONRepresentation.Path] = []

        for mine in ours {
            let original = baseByID[mine["id"]!]
            if let yours = theirsByID[mine["id"]!] {
                let result = mergedByShape(mine, yours, base: original, under: schema)
                conflicts += result.conflicts.map { [.index(merged.count)] + $0 }
                merged.append(result.merged)
            } else if let original, mine != original {
                // Theirs removed what ours changed.
                conflicts.append([.index(merged.count)])
                if case .ours = favoring { merged.append(mine) }
            } else if original == nil {
                merged.append(mine)  // Ours added it.
            }
        }
        for yours in theirs where oursByID[yours["id"]!] == nil {
            let original = baseByID[yours["id"]!]
            if let original, yours != original {
                // Ours removed what theirs changed.
                conflicts.append([.index(merged.count)])
                if case .theirs = favoring { merged.append(yours) }
            } else if original == nil {
                merged.append(yours)  // Theirs added it.
            }
        }
        return (merged, conflicts)
    }
}

// MARK: - Mergeable values

private extension JSONMerge {
    /// The type of each `Mergeable` value, by its path in the schema: an
    /// array's element at index 0 and a dictionary's value at key `"*"`.
    ///
    /// A metatype holds no state, and a `Mergeable` merge is a pure function of
    /// its arguments, so sharing them across threads is safe.
    struct Mergeables: @unchecked Sendable {
        let types: [JSONRepresentation.Path: any (Mergeable & Codable).Type]
    }

    /// `merged`, at `path`, with each `Mergeable` value both sides changed
    /// replaced by its own merge of `ours` and `theirs`. Appends the path of
    /// each value it replaced to `settled`.
    ///
    /// `schemaPath` is `path` as the schema spells it. Elements of an array
    /// pair up by `"id"`, or by position when no array changed its length.
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
        if let type = mergeables.types[schemaPath] {
            // As `DefaultMergeStrategy` does, both sides making the same change still merges, so two raises add up.
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
            var result: [JSONRepresentation] = []
            for (index, value) in elements.enumerated() {
                if let id = value["id"] {
                    // An identified element pairs with the same `"id"` on each side, wherever it is.
                    let (mine, yours, original) = (mine.first { $0["id"] == id }, yours.first { $0["id"] == id }, originals?.first { $0["id"] == id })
                    result.append(child(value, at: .index(index), spelled: .index(0), mine, yours, original, under: element, settled: &settled))
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
    /// Each element keyed by its `"id"`, keeping the first of any repeated id,
    /// or `nil` when one has no `"id"`.
    var byID: [JSONRepresentation: JSONRepresentation]? {
        var result: [JSONRepresentation: JSONRepresentation] = [:]
        for element in self {
            guard let id = element["id"] else { return nil }
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

    /// The element schema when this is an array of objects with an `"id"` property.
    var identifiedElement: JSONSchema? {
        guard case .array(let element) = unwrapped, case .object(let properties) = element.unwrapped,
              properties.contains(where: { $0.key == "id" }) else { return nil }
        return element
    }
}

extension JSONSchema {
    /// This schema without any `.optional` around it.
    var unwrapped: JSONSchema {
        if case .optional(let wrapped) = self { wrapped.unwrapped } else { self }
    }
}
