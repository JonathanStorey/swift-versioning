import Foundation

extension RecordContainer {
    /// What the container needs from one registered record type.
    struct Registration: Sendable {
        /// `ours` merged with `theirs`, from `base` when there is one, by the type's own merge.
        let merge: @Sendable (_ ours: JSONRepresentation, _ theirs: JSONRepresentation, _ base: JSONRepresentation?) throws -> JSONRepresentation
    }

    /// Registers `type`, so its records can merge on arrival by the type's own merge,
    /// ``DefaultMergeStrategy`` unless the type implements another.
    ///
    /// ```swift
    /// let container = RecordContainer()
    /// container.register(Note.self)
    /// ```
    func register<Record: Codable & Identifiable & Mergeable>(_ type: Record.Type) where Record.ID == UUID {
        let registration = Registration { ours, theirs, base in
            let mine = try ours.decode(Record.self)
            let other = try theirs.decode(Record.self)
            guard let base else { return try JSONRepresentation(mine.merging(with: other)) }
            return try JSONRepresentation(mine.merging(with: other, from: base.decode(Record.self)))
        }
        locked { registrations[Self.recordType(of: type)] = registration }
    }

    /// The registration for the record type named `type`.
    func registration(for type: String) throws -> Registration {
        guard let registration = locked({ registrations[type] }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The record type \(type) is not registered."))
        }
        return registration
    }

    /// The record type a Swift type saves as, its name, as in `"Note"`.
    static func recordType(of type: Any.Type) -> String {
        String(describing: type)
    }
}
