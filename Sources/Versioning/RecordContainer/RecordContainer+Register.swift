import Foundation

extension RecordContainer {
    /// A record type the container can merge, decode and encode.
    typealias RecordType = any (Codable & Mergeable).Type

    /// Registers `type`, so its records can merge on arrival by the type's own merge,
    /// ``DefaultMergeStrategy`` unless the type implements another.
    ///
    /// ```swift
    /// let container = RecordContainer()
    /// container.register(Note.self)
    /// ```
    func register<Record: Codable & Identifiable & Mergeable>(_ type: Record.Type) {
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

    /// The row's id and the record's name for `record`: its `UUID` id itself, or, for any
    /// other id, a stable hash of the record type and the id's JSON, as in `"Note|\"intro\""`.
    ///
    /// The same id always names the same record, so two devices that create it apart
    /// save one record. The type is part of the hash because a record name is unique in
    /// its zone across every type. A `UUID` id is kept as it is so a reference to the
    /// record can be read back as the id.
    static func recordID<Record: Identifiable>(of record: Record) throws -> UUID where Record.ID: Encodable {
        if let id = record.id as? UUID { return id }
        let id = try JSONRepresentation(record.id)
        return UUID(stableHashOf: recordType(of: Record.self) + "|" + id.description)
    }
}

extension JSONRepresentation {
    /// This version merged with `theirs`, from `base` when there is one, by `type`'s own merge.
    func merging<Record: Codable & Mergeable>(with theirs: JSONRepresentation, from base: JSONRepresentation?, as type: Record.Type) throws -> JSONRepresentation {
        let ours = try decode(Record.self)
        let other = try theirs.decode(Record.self)
        guard let base else { return try JSONRepresentation(ours.merging(with: other)) }
        return try JSONRepresentation(ours.merging(with: other, from: base.decode(Record.self)))
    }
}
