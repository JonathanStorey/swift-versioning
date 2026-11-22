#if canImport(CloudKit)
import CloudKit

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension RecordContainer {
    /// Saves the server's version of `record`, decoded as its registered type, with its
    /// system fields as `metadata`.
    ///
    /// The record's name, a UUID from ``recordID(for:type:)``, is the row's id, and its zone and
    /// owner come from the record's zone. The decoded value merges into the row as ``save(their:id:zone:type:metadata:)``
    /// describes. Throws, saving nothing, when the record's name is not a UUID, its type is
    /// not registered, or the type cannot decode it.
    func save(their record: CKRecord) throws {
        let recordID = record.recordID
        try save(
            their: json(of: record),
            id: recordID.rowID(),
            zone: Zone(recordID.zoneID.zoneName, owner: recordID.zoneID.ownerName),
            type: record.recordType,
            metadata: record.systemFields
        )
    }

    /// The record to upload for the row `id`, or `nil` when it has nothing to upload.
    ///
    /// The record starts from the row's system fields, so the server can tell which version
    /// it replaces, or, before the server first confirms it or when they cannot be read,
    /// from a new record in the row's zone. `ours` is encoded into it as the registered type. A row that is synced,
    /// deleted, waiting to merge, or rejected sends nothing.
    ///
    /// ```swift
    /// let record = try container.send(id: note.id)
    /// ```
    func send(id: UUID) throws -> CKRecord? {
        guard let row = try row(id: id), let ours = row.ours, row.status == .waitingToUpload, !row.isDeleted else { return nil }
        let record = row.metadata.flatMap(CKRecord.init(systemFields:)) ?? CKRecord(
            recordType: row.type,
            recordID: CKRecord.ID(recordName: id.uuidString, zoneID: CKRecordZone.ID(zoneName: row.zone.name, ownerName: row.zone.owner))
        )
        try CKRecordEncoder().encode(ours, as: registeredType(named: row.type), to: record)
        return record
    }

    /// Saves `record`, which this device sent and the server saved, as the row's `base`,
    /// with its system fields as `metadata`.
    ///
    /// Nothing merges, as ``Row/confirm(_:)`` describes, so changes saved while the record
    /// was on its way stay waiting to upload.
    func save(sent record: CKRecord) throws {
        let json = try json(of: record)
        try update(id: record.recordID.rowID()) { row in
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
    func save(failed record: CKRecord, error: CKError) throws {
        if error.code == .serverRecordChanged, let server = error.serverRecord {
            return try save(their: server)
        }
        let id = try record.recordID.rowID()
        switch error.code {
        case .unknownItem:
            try update(id: id) { $0.metadata = nil }
        case .zoneNotFound, .batchRequestFailed, .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return
        default:
            try update(id: id) { $0.error = error.localizedDescription }
        }
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private extension RecordContainer {
    /// The JSON of `record` decoded as its registered type.
    func json(of record: CKRecord) throws -> JSONRepresentation {
        try CKRecordDecoder().json(registeredType(named: record.recordType), from: record)
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

private extension CKRecord.ID {
    /// The row's id: the record's name, which must be a UUID.
    func rowID() throws -> UUID {
        guard let id = UUID(uuidString: recordName) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Record name \"\(recordName)\" is not a UUID."))
        }
        return id
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

    /// The record's system fields, archived, without its values.
    var systemFields: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
}
#endif
