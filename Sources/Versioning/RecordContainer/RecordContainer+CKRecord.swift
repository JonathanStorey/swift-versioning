#if canImport(CloudKit)
import CloudKit
import CoreLocation

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension RecordContainer {
    /// Saves the server's version of `record`: its fields, copied as they are with no schema,
    /// and its system fields as `metadata`. See ``save(their:id:zone:owner:type:metadata:merging:)``.
    ///
    /// Throws when the record's name is not a `UUID`, such as a `CKShare`, because a row is
    /// keyed by `UUID`, or when the database fails. A conflict never throws: it waits in the row.
    func save(their record: CKRecord, merging merge: RecordRepresentation.FieldsMerge = { try $0.merging(with: $1, from: $2) }) throws {
        guard let id = UUID(uuidString: record.recordID.recordName) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The record name \(record.recordID.recordName) is not a UUID."))
        }
        let zone = record.recordID.zoneID
        try save(their: RecordRepresentation.Fields(record), id: id, zone: zone.zoneName, owner: zone.ownerName, type: record.recordType, metadata: record.systemFields, merging: merge)
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Dictionary where Key == String, Value == RecordRepresentation.Field {
    /// Every field of `record`, each tagged with its CloudKit type, and encrypted
    /// values wrapped in ``RecordRepresentation/Field/encrypted(_:)``.
    init(_ record: CKRecord) {
        self = [:]
        for key in record.encryptedValues.allKeys() {
            if let value = record.encryptedValues[key], let field = RecordRepresentation.Field(value) { self[key] = .encrypted(field) }
        }
        for key in record.allKeys() where self[key] == nil {
            if let value = record[key], let field = RecordRepresentation.Field(value) { self[key] = field }
        }
    }
}

extension RecordRepresentation.Field {
    /// A CloudKit value as a field, or `nil` for a type CloudKit does not store.
    init?(_ value: Any) {
        switch value {
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            // A Double that holds a whole number still bridges to Int64, so read the stored type.
            self = CFNumberIsFloatType(number as CFNumber) ? .double(number.doubleValue) : .int64(number.int64Value)
        case let date as Date:
            self = .timestamp(date)
        case let data as Data:
            self = .bytes(data)
        case let location as CLLocation:
            self = .location(Location(location))
        case let reference as CKRecord.Reference:
            self = .reference(RecordRepresentation.Reference(recordName: reference.recordID.recordName, action: reference.action == .deleteSelf ? .deleteSelf : .none))
        case let asset as CKAsset:
            self = .asset(asset.fileURL)
        case let items as [Any]:
            self = .list(items.compactMap { Self($0) })
        default:
            return nil
        }
    }
}

private extension CKRecord {
    /// The record's system fields, archived as CloudKit recommends, so a later upload
    /// can rebuild the record with its change tag.
    var systemFields: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
}
#endif
