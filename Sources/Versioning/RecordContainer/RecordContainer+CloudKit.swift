#if canImport(CloudKit)
import CloudKit

extension RecordContainer {
    /// Saves the server's version of `record`, decoded as its registered type, with its
    /// system fields as `metadata`.
    ///
    /// The record's name, a UUID from ``recordID(for:type:)``, is the row's id, and its zone and
    /// owner come from the record's zone. The decoded value merges into the row as ``save(their:id:zone:type:metadata:)``
    /// describes. Throws, saving nothing, when the record's name is not a UUID, its type is
    /// not registered, or the type cannot decode it.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func save(their record: CKRecord) throws {
        let recordID = record.recordID
        guard let id = UUID(uuidString: recordID.recordName) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Record name \"\(recordID.recordName)\" is not a UUID."))
        }
        let registered = try registeredType(named: record.recordType)
        try save(
            their: CKRecordDecoder().json(registered, from: record),
            id: id,
            zone: Zone(recordID.zoneID.zoneName, owner: recordID.zoneID.ownerName),
            type: record.recordType,
            metadata: record.systemFields
        )
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private extension CKRecordDecoder {
    /// The JSON of `record` decoded as `type`, generic so a registered metatype opens here.
    func json<T: Codable>(_ type: T.Type, from record: CKRecord) throws -> JSONRepresentation {
        try JSONRepresentation(decode(type, from: record))
    }
}

private extension CKRecord {
    /// The record's system fields, archived, without its values.
    var systemFields: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
}
#endif
