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
    func register<Record: Codable & Identifiable & Mergeable>(_ type: Record.Type) where Record.ID == UUID {
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
