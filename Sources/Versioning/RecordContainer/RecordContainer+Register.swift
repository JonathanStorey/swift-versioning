import Foundation

extension RecordContainer {
    /// A record type the container can merge, decode and encode.
    typealias RecordType = any (Codable & Mergeable).Type

    /// A registered record type, and the key path to the property that identifies it.
    struct Registration {
        let type: RecordType
        let id: AnyKeyPath
    }

    /// Registers `type`, identified by the property at `id`, so its records can be saved
    /// and can merge on arrival by the type's own merge, ``DefaultMergeStrategy`` unless the
    /// type implements another.
    ///
    /// A plain struct needs no `Identifiable` conformance, the way `List(_:id:)` takes any
    /// data:
    ///
    /// ```swift
    /// container.register(Page.self, id: \.slug)
    /// ```
    func register<Record: Codable & Mergeable, ID: Encodable>(_ type: Record.Type, id: KeyPath<Record, ID>) {
        locked { registrations[Self.recordType(of: type)] = Registration(type: type, id: id) }
    }

    /// Registers an `Identifiable` `type`, identified by its `id`.
    ///
    /// ```swift
    /// container.register(Note.self)
    /// ```
    func register<Record: Codable & Identifiable & Mergeable>(_ type: Record.Type) where Record.ID: Encodable {
        register(type, id: \.id)
    }

    /// The registration for the record type named `type`.
    func registration(named type: String) throws -> Registration {
        guard let registration = locked({ registrations[type] }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The record type \(type) is not registered."))
        }
        return registration
    }

    /// The registered Swift type for the record type named `type`.
    func registeredType(named type: String) throws -> RecordType {
        try registration(named: type).type
    }

    /// The record type a Swift type saves as, its name, as in `"Note"`.
    static func recordType(of type: Any.Type) -> String {
        String(describing: type)
    }

    /// The row's id and the record's name for `record`, from the id its type registered.
    /// See ``recordID(for:type:)``. Throws when the type is not registered.
    func recordID<Record>(of record: Record) throws -> UUID {
        let type = Self.recordType(of: Record.self)
        guard let id = record[keyPath: try registration(named: type).id] as? any Encodable else {
            throw EncodingError.invalidValue(record, .init(codingPath: [], debugDescription: "The registered id of \(type) is not Encodable."))
        }
        return try Self.recordID(for: id, type: type)
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

extension JSONRepresentation {
    /// This version merged with `theirs`, from `base` when there is one, by `type`'s own merge.
    func merging<Record: Codable & Mergeable>(with theirs: JSONRepresentation, from base: JSONRepresentation?, as type: Record.Type) throws -> JSONRepresentation {
        let ours = try decode(Record.self)
        let other = try theirs.decode(Record.self)
        guard let base else { return try JSONRepresentation(ours.merging(with: other)) }
        return try JSONRepresentation(ours.merging(with: other, from: base.decode(Record.self)))
    }
}
