import Foundation

extension RecordContainer {
    /// A record type the container can merge, decode and encode.
    typealias RecordType = any (Codable & Mergeable).Type

    /// Registers `type`, so its records can merge on arrival by the type's own merge,
    /// ``DefaultMergeStrategy`` unless the type implements another.
    ///
    /// A plain struct needs no `Identifiable` conformance. Its id is chosen where it is
    /// saved, the way `List(_:id:)` takes any data.
    ///
    /// ```swift
    /// let container = RecordContainer()
    /// container.register(Note.self)
    /// ```
    func register<Record: Codable & Mergeable>(_ type: Record.Type) {
        locked { registrations[Self.recordType(of: type)] = type }
    }

    /// The registered Swift type for the record type named `type`.
    func registeredType(named type: String) throws -> RecordType {
        guard let registered = locked({ registrations[type] }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The record type \(type) is not registered."))
        }
        return registered
    }

    /// The record type a Swift type saves as, its name, as in `"Note"`.
    static func recordType(of type: Any.Type) -> String {
        String(describing: type)
    }

    /// The row's id and the record's name for the id `id` of a record of type `type`: a
    /// `UUID` id itself, or, for any other id, a stable hash of the record type and the
    /// id's JSON, as in `"Page|\"intro\""`.
    ///
    /// The same id always names the same record, so two devices that create it apart
    /// save one record. The type is part of the hash because a record name is unique in
    /// its zone across every type. A `UUID` id is kept as it is so a reference to the
    /// record can be read back as the id.
    static func recordID(for id: any Encodable, type: String) throws -> UUID {
        if let id = id as? UUID { return id }
        return UUID(stableHashOf: type + "|" + (try JSONRepresentation(id)).description)
    }
}

extension RecordContainer {
    /// `ours` merged with `theirs`, from `base` when there is one, by `type`'s own merge,
    /// with any file the merge wrote, as a merged `@Asset`, copied into the row `id`'s folder.
    ///
    /// The merge settles itself, so the user never sees it:
    /// - Values that still conflict after the type's merge are settled by ``mergeStrategy``.
    /// - A version that cannot be read as `type` counts as missing: an unreadable `base`
    ///   makes a two-way merge, an unreadable `theirs` keeps `ours`, and an unreadable `ours`
    ///   takes `theirs`. Fields the type does not have are dropped.
    /// - A key one version lacks, as a version saved before a field was added, is read from
    ///   the other version, so the older shape still decodes and leaves that field unchanged.
    func merged<Record: Codable & Mergeable>(_ ours: JSONRepresentation, with theirs: JSONRepresentation, from base: JSONRepresentation?, as type: Record.Type, id: UUID) throws -> JSONRepresentation {
        let mine = try? ours.filling(from: theirs).decode(Record.self)
        let other = try? theirs.filling(from: ours).decode(Record.self)
        let original = try? base?.filling(from: ours.filling(from: theirs)).decode(Record.self)
        let merged: Record
        switch (mine, other) {
        case let (mine?, other?): merged = try settled(mine, with: other, from: original)
        case let (nil, other?): merged = other
        case (_?, nil): return ours
        case (nil, nil): return theirs
        }
        return storingAssets(Self.assetFiles(of: merged), in: try JSONRepresentation(merged), id: id)
    }
}

private extension RecordContainer {
    /// `ours` merged with `theirs` by the type's own merge, and, where that conflicts, again
    /// with ``mergeStrategy`` keeping its side at each conflicting value.
    func settled<Record: Codable & Mergeable>(_ ours: Record, with theirs: Record, from base: Record?) throws(MergeConflict) -> Record {
        do {
            if let base { return try ours.merging(with: theirs, from: base) }
            return try ours.merging(with: theirs)
        } catch {
            let strategy = DefaultMergeStrategy<Record>(favoring: mergeStrategy.favoring?.retyped())
            if let base { return try ours.merging(with: theirs, from: base, using: strategy) }
            return try ours.merging(with: theirs, using: strategy)
        }
    }
}

private extension JSONRepresentation {
    /// This object with each top-level key it lacks taken from `other`.
    func filling(from other: JSONRepresentation) -> JSONRepresentation {
        guard case .object(var pairs) = self, case .object(let others) = other else { return self }
        let keys = Set(pairs.map { $0.key })
        pairs += others.filter { !keys.contains($0.key) }
        return .object(pairs)
    }
}
