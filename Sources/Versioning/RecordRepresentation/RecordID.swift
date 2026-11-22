import Foundation

/// Where a record of type `Record` lives: its name, its zone, and the zone's owner. It is
/// everything needed to find the record again, so it can be stored in a reference or handed
/// to a view.
///
/// ```swift
/// let folder = try RecordID(folder, zone: "Notes")          // an Identifiable folder
/// let page = try RecordID(page, id: \.slug, zone: "Pages")   // a plain struct
/// ```
///
/// The record type is `Record` itself, so it is not stored. The name is the record's `UUID`
/// id, or a stable hash of any other id, the same name the record is saved under. The
/// owner is `"__defaultOwner__"` for a zone in your own database, or the sharer's user
/// record name for a zone shared with you, so it is the same zone seen from this device.
public struct RecordID<Record>: Hashable, Codable, Sendable {
    /// The record's name in CloudKit.
    public var name: UUID
    public var zone: String
    /// The zone's owner, `"__defaultOwner__"` in your own database.
    public var owner: String

    public init(name: UUID, zone: String, owner: String = "__defaultOwner__") {
        self.name = name
        self.zone = zone
        self.owner = owner
    }
}

extension RecordID {
    /// The id of `record`, identified by the property at `id`.
    public init<ID: Encodable>(_ record: Record, id: KeyPath<Record, ID>, zone: String, owner: String = "__defaultOwner__") throws {
        let name = try RecordContainer.recordID(for: record[keyPath: id], type: RecordContainer.recordType(of: Record.self))
        self.init(name: name, zone: zone, owner: owner)
    }

    /// The id of an `Identifiable` `record`.
    public init(_ record: Record, zone: String, owner: String = "__defaultOwner__") throws where Record: Identifiable, Record.ID: Encodable {
        try self.init(record, id: \.id, zone: zone, owner: owner)
    }
}
