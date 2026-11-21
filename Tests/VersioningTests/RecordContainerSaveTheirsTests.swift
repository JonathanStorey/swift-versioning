import Foundation
import Testing
@testable import Versioning

private struct Note: Codable, Identifiable {
    var id: UUID
    var title = "Base"
    var body = "Base"
}

private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let metadata = Data([7])

private func fields(_ note: Note) throws -> RecordRepresentation.Fields {
    try RecordRepresentation.Fields(JSONRepresentation(note), schema: RecordSchema(for: Note.self))
}

private extension RecordContainer {
    func save(their note: Note) throws {
        try save(their: fields(note), id: note.id, zone: "Notes", owner: "__defaultOwner__", type: "Note", metadata: metadata)
    }
}

@Suite struct RecordContainerSaveTheirsTests {
    @Test func aNewRecordBecomesItsBase() throws {
        let container = RecordContainer()
        try container.save(their: Note(id: id))
        let row = try #require(try container.row(id: id))
        #expect(row == RecordContainer.Row(id: id, zone: "Notes", type: "Note", metadata: metadata, base: try fields(Note(id: id))))
        #expect(row.status == .synced)
    }

    @Test func aNewerVersionReplacesTheBaseWhenNothingIsWaiting() throws {
        let container = RecordContainer()
        try container.save(their: Note(id: id))
        try container.save(their: Note(id: id, title: "Newer"))
        #expect(try container.row(id: id)?.base == fields(Note(id: id, title: "Newer")))
    }

    @Test func localChangesMergeWithTheServersChanges() throws {
        let container = RecordContainer()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Ours"), zone: "Notes")
        try container.save(their: Note(id: id, body: "Theirs"))

        let row = try #require(try container.row(id: id))
        #expect(row.ours == (try fields(Note(id: id, title: "Ours", body: "Theirs"))))
        #expect(row.base == (try fields(Note(id: id, body: "Theirs"))))
        #expect(row.status == .waitingToUpload)
    }

    @Test func aChangeTheServerAlreadyHasLeavesNothingToUpload() throws {
        let container = RecordContainer()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Same"), zone: "Notes")
        try container.save(their: Note(id: id, title: "Same"))
        #expect(try container.row(id: id)?.status == .synced)
    }

    @Test func aConflictWaitsWithoutTouchingOursOrBase() throws {
        let container = RecordContainer()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Ours"), zone: "Notes")
        try container.save(their: Note(id: id, title: "Theirs"))

        let row = try #require(try container.row(id: id))
        #expect(row.ours == (try fields(Note(id: id, title: "Ours"))))
        #expect(row.base == (try fields(Note(id: id))))
        #expect(row.theirs == (try fields(Note(id: id, title: "Theirs"))))
        #expect(row.status == .conflict("Both sides changed $.title"))
    }

    @Test func aNewerVersionCanSettleAConflict() throws {
        let container = RecordContainer()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Ours"), zone: "Notes")
        try container.save(their: Note(id: id, title: "Theirs"))
        try container.save(their: Note(id: id, title: "Ours"))
        #expect(try container.row(id: id)?.status == .synced)
    }

    @Test func aRecordsTypeCanSupplyItsOwnMerge() throws {
        let container = RecordContainer()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Ours"), zone: "Notes")
        try container.save(their: fields(Note(id: id, title: "Theirs")), id: id, zone: "Notes", owner: "__defaultOwner__", type: "Note", metadata: metadata) { ours, _, _ in ours }
        #expect(try container.row(id: id)?.ours == fields(Note(id: id, title: "Ours")))
        #expect(try container.row(id: id)?.base == fields(Note(id: id, title: "Theirs")))
    }
}

#if canImport(CloudKit)
import CloudKit
import CoreLocation

@Suite struct RecordContainerSaveCKRecordTests {
    @Test func aCKRecordsFieldsAreCopiedWithTheirTypes() throws {
        guard #available(macOS 12, iOS 15, tvOS 15, watchOS 8, *) else { return }
        let zone = CKRecordZone.ID(zoneName: "Notes", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "Note", recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zone))
        record["title"] = "Hello"
        record["count"] = 3
        record["score"] = 2.0
        record["due"] = Date(timeIntervalSinceReferenceDate: 100)
        record["tags"] = ["a", "b"]
        record["folder"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: "F", zoneID: zone), action: .deleteSelf)
        record.encryptedValues["pin"] = 42

        let container = RecordContainer()
        try container.save(their: record)
        let row = try #require(try container.row(id: id))
        #expect(row.zone == "Notes")
        #expect(row.owner == CKCurrentUserDefaultName)
        #expect(row.type == "Note")
        #expect(row.metadata?.isEmpty == false)
        #expect(row.base == [
            "title": .string("Hello"),
            "count": .int64(3),
            "score": .double(2),
            "due": .timestamp(Date(timeIntervalSinceReferenceDate: 100)),
            "tags": .list([.string("a"), .string("b")]),
            "folder": .reference(.init(recordName: "F", action: .deleteSelf)),
            "pin": .encrypted(.int64(42)),
        ])
    }

    @Test func aRecordNameThatIsNotAUUIDThrows() {
        guard #available(macOS 12, iOS 15, tvOS 15, watchOS 8, *) else { return }
        let record = CKRecord(recordType: "cloudkit.share", recordID: CKRecord.ID(recordName: "share-1"))
        #expect(throws: DecodingError.self) { try RecordContainer().save(their: record) }
    }
}
#endif
