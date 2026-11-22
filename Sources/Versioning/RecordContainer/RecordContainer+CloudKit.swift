#if canImport(CloudKit)
import CloudKit

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension RecordContainer {
    /// Saves the server's version of `record`, decoded as its registered type, with its
    /// system fields as `metadata`.
    ///
    /// The record's name, a UUID from ``recordID(for:type:)``, is the row's id, and its zone and
    /// owner come from the record's zone. The decoded value merges into the row as ``save(their:id:zone:type:metadata:)``
    /// describes. A record whose type is not registered, or that the type cannot decode, is
    /// kept whole in `metadata` with the reason in `error`, so nothing is lost. A record whose
    /// name is not a UUID was not saved by this package and is skipped, as is a `CKShare`.
    /// Throws only when the database fails.
    func save(their record: CKRecord) throws(DatabaseError) {
        guard !(record is CKShare), let id = record.recordID.rowID else { return }
        let json: JSONRepresentation
        do {
            json = try self.json(of: record)
        } catch {
            return try save(unreadable: record, id: id, reason: error)
        }
        try save(their: json, id: id, zone: record.recordID.zone, type: record.recordType, metadata: record.systemFields)
    }

    /// Saves the server's version of each of `records`, as `save(their:)` does for one record,
    /// in one transaction.
    ///
    /// ```swift
    /// try container.save(their: changes.modifications.map(\.record))
    /// ```
    func save(their records: some Sequence<CKRecord>) throws(DatabaseError) {
        try transaction { () throws(DatabaseError) in
            for record in records { try save(their: record) }
        }
    }

    /// Saves each of `records`, which this device sent and the server saved, as
    /// `save(sent:)` does for one record, in one transaction.
    func save(sent records: some Sequence<CKRecord>) throws(DatabaseError) {
        try transaction { () throws(DatabaseError) in
            for record in records { try save(sent: record) }
        }
    }

    /// Saves that the server no longer has each record in `ids`, as
    /// `save(deleted:)` does for one id, in one transaction.
    func save(deleted ids: some Sequence<CKRecord.ID>) throws(DatabaseError) {
        try transaction { () throws(DatabaseError) in
            for id in ids { try save(deleted: id) }
        }
    }

    /// The records waiting to upload, as saves and deletes, for telling a sync engine what
    /// to send, as on launch after a change was saved but never handed to it.
    ///
    /// ```swift
    /// let pending = try container.pendingChanges()
    /// syncEngine.state.add(pendingRecordZoneChanges: pending.saves.map { .saveRecord($0) } + pending.deletes.map { .deleteRecord($0) })
    /// ```
    func pendingChanges() throws(DatabaseError) -> (saves: [CKRecord.ID], deletes: [CKRecord.ID]) {
        var pending: (saves: [CKRecord.ID], deletes: [CKRecord.ID]) = ([], [])
        for row in try pendingRows() {
            let recordID = CKRecord.ID(recordName: row.id.uuidString, zoneID: row.zone.zoneID)
            if row.isDeleted { pending.deletes.append(recordID) } else { pending.saves.append(recordID) }
        }
        return pending
    }

    /// The record to upload for the row `id`, or `nil` when it has nothing to upload.
    ///
    /// The record starts from the row's system fields, so the server can tell which version
    /// it replaces, or, before the server first confirms it or when they cannot be read,
    /// from a new record in the row's zone. `ours` is encoded into it as the registered type.
    /// A row that is synced, deleted, waiting to merge, or rejected sends nothing. A row that
    /// cannot be encoded sends nothing, with the reason in `error`. Throws only when the
    /// database fails.
    ///
    /// ```swift
    /// let record = try container.send(id: note.id)
    /// ```
    func send(id: UUID) throws(DatabaseError) -> CKRecord? {
        guard let row = try row(id: id), let ours = row.ours, row.status == .waitingToUpload, !row.isDeleted else { return nil }
        let record = row.metadata.flatMap(CKRecord.init(systemFields:)) ?? CKRecord(
            recordType: row.type,
            recordID: CKRecord.ID(recordName: id.uuidString, zoneID: row.zone.zoneID)
        )
        do {
            try CKRecordEncoder().encode(ours, as: registeredType(named: row.type), to: record)
            return record
        } catch {
            try update(id: id) { $0.error = "This device could not send its \(row.type): \(error)" }
            return nil
        }
    }

    /// Saves `record`, which this device sent and the server saved, as the row's `base`,
    /// with its system fields as `metadata`.
    ///
    /// Nothing merges, as ``Row/confirm(_:)`` describes, so changes saved while the record
    /// was on its way stay waiting to upload. Throws only when the database fails.
    func save(sent record: CKRecord) throws(DatabaseError) {
        guard let id = record.recordID.rowID else { return }
        let json: JSONRepresentation
        do {
            json = try self.json(of: record)
        } catch {
            return try save(unreadable: record, id: id, reason: error)
        }
        try update(id: id) { row in
            row.metadata = record.systemFields
            row.confirm(json)
        }
    }

    /// Saves why the server did not save `record`, which this device sent.
    ///
    /// - A newer server version merges in, as `save(their:)` describes, and the next
    ///   send replaces that version.
    /// - A record the server no longer has loses its `metadata`, so the next send creates it again.
    /// - A missing zone, or a failure worth retrying, changes nothing, so the record is sent again.
    /// - Any other error is saved in `error`, and nothing more uploads until the record is saved again.
    ///
    /// Throws only when the database fails.
    func save(failed record: CKRecord, error: CKError) throws(DatabaseError) {
        if error.code == .serverRecordChanged, let server = error.serverRecord {
            return try save(their: server)
        }
        guard let id = record.recordID.rowID else { return }
        switch error.code {
        case .unknownItem:
            try update(id: id) { $0.metadata = nil }
        case let code where code.isWorthRetrying:
            return
        default:
            try update(id: id) { $0.error = error.localizedDescription }
        }
    }

    /// The id of the record to delete for the row `id`, or `nil` when it has no delete
    /// waiting to upload.
    ///
    /// ```swift
    /// let recordID = try container.send(deleted: note.id)
    /// ```
    func send(deleted id: UUID) throws(DatabaseError) -> CKRecord.ID? {
        guard let row = try row(id: id), row.isDeleted, row.status == .waitingToUpload else { return nil }
        return CKRecord.ID(recordName: id.uuidString, zoneID: row.zone.zoneID)
    }

    /// Saves that the server no longer has the record `id`, because it confirmed this
    /// device's delete or another device deleted it, as `save(deleted:)` for a row id describes.
    func save(deleted id: CKRecord.ID) throws(DatabaseError) {
        guard let rowID = id.rowID else { return }
        try save(deleted: rowID)
    }

    /// Removes every row in the zone `zoneID` on this device, as `clear(in:)` for a `Zone` describes.
    ///
    /// ```swift
    /// for deletion in changes.deletions { try container.clear(in: deletion.zoneID) }
    /// ```
    func clear(in zoneID: CKRecordZone.ID) throws(DatabaseError) {
        try clear(in: Zone(zoneID.zoneName, owner: zoneID.ownerName))
    }

    /// Saves why the server did not delete the record `id`, which this device sent.
    ///
    /// - A record the server no longer has is already deleted, so the row is removed.
    /// - A missing zone, or a failure worth retrying, changes nothing, so the delete is sent again.
    /// - Any other error is saved in `error`, and the delete waits until the record is deleted
    ///   or saved again.
    func save(failed id: CKRecord.ID, error: CKError) throws(DatabaseError) {
        guard let rowID = id.rowID else { return }
        switch error.code {
        case .unknownItem:
            try save(deleted: rowID)
        case let code where code.isWorthRetrying:
            return
        default:
            try update(id: rowID) { $0.error = error.localizedDescription }
        }
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private extension RecordContainer {
    /// The JSON of `record` decoded as its registered type.
    func json(of record: CKRecord) throws -> JSONRepresentation {
        try CKRecordDecoder().json(registeredType(named: record.recordType), from: record)
    }

    /// Keeps `record`, which this device cannot read, whole in the row's `metadata`, with
    /// `reason` in `error`, so a later version of the app can read it. `ours` and `base` are
    /// unchanged, and nothing uploads until it is settled.
    func save(unreadable record: CKRecord, id: UUID, reason: any Error) throws(DatabaseError) {
        try update(id: id, inserting: Row(id: id, zone: record.recordID.zone, type: record.recordType)) { row in
            row.metadata = record.archived
            row.error = "This device could not read the server's \(record.recordType): \(reason)"
        }
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private extension CKRecordDecoder {
    /// The JSON of `record` decoded as `type`, generic so a registered metatype opens here.
    func json<T: Codable>(_ type: T.Type, from record: CKRecord) throws -> JSONRepresentation {
        try JSONRepresentation(decode(type, from: record))
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private extension CKRecordEncoder {
    /// Encodes `json`, decoded as `type`, into `record`, generic so a registered metatype opens here.
    func encode<T: Codable>(_ json: JSONRepresentation, as type: T.Type, to record: CKRecord) throws {
        try encode(json.decode(type), to: record)
    }
}

private extension CKError.Code {
    /// A missing zone, or a failure that may pass, after which a record is sent again unchanged.
    var isWorthRetrying: Bool {
        switch self {
        case .zoneNotFound, .batchRequestFailed, .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy: true
        default: false
        }
    }
}

private extension Zone {
    /// The zone's CloudKit id, with its owner.
    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: owner)
    }
}

private extension CKRecord.ID {
    /// The row's id: the record's name as a UUID, or `nil` for a record this package did not name.
    var rowID: UUID? {
        UUID(uuidString: recordName)
    }

    /// The record's zone, with its owner.
    var zone: Zone {
        Zone(zoneID.zoneName, owner: zoneID.ownerName)
    }
}

private extension CKRecord {
    /// A record with the system fields archived in `systemFields`, and no values, or `nil`
    /// when they cannot be read.
    convenience init?(systemFields: Data) {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        self.init(coder: unarchiver)
    }

    /// The whole record archived, its values with its system fields.
    var archived: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encode(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// The record's system fields, archived, without its values.
    var systemFields: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
}
#endif
