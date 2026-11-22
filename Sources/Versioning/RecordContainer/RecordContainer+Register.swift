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
    func merged<Record: Codable & Mergeable>(_ ours: JSONRepresentation, with theirs: JSONRepresentation, from base: JSONRepresentation?, as type: Record.Type, id: UUID) throws -> JSONRepresentation {
        let mine = try ours.decode(Record.self)
        let other = try theirs.decode(Record.self)
        let merged = try base.map { try mine.merging(with: other, from: $0.decode(Record.self)) } ?? mine.merging(with: other)
        return storingAssets(Self.assetFiles(of: merged), in: try JSONRepresentation(merged), id: id)
    }
}
