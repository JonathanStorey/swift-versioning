import Foundation
import Testing
@testable import Versioning

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title: String
}

private extension RecordContainer {
    /// A container holding `note` as the server's version, synced.
    static func synced(_ note: Note) throws -> RecordContainer {
        let container = RecordContainer()
        try container.save(their: JSONRepresentation(note), id: note.id, zone: "Notes", type: "Note", metadata: Data([1]))
        return container
    }
}

@Suite struct RecordContainerDeleteTests {
    @Test func aRecordNeverUploadedIsRemovedAtOnce() throws {
        let container = RecordContainer()
        let note = Note(title: "Draft")
        try container.save(our: note, zone: "Notes")
        try container.delete(id: note.id)
        #expect(try container.row(id: note.id) == nil)
    }

    @Test func aSyncedRecordWaitsToUploadItsDelete() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.save(our: Note(id: note.id, title: "Edited"), zone: "Notes")
        try container.delete(id: note.id)

        let row = try #require(try container.row(id: note.id))
        #expect(row.isDeleted)
        #expect(row.ours == nil)
        #expect(row.status == .waitingToUpload)
    }

    @Test func savingAgainUndoesADelete() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.delete(id: note.id)
        try container.save(our: note, zone: "Notes")
        #expect(try container.row(id: note.id)?.isDeleted == false)
    }

    @Test func aConfirmedDeleteRemovesTheRow() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.delete(id: note.id)
        try container.save(deleted: note.id)
        #expect(try container.row(id: note.id) == nil)
    }

    @Test func aDeleteFromAnotherDeviceRemovesASyncedRow() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.save(deleted: note.id)
        #expect(try container.row(id: note.id) == nil)
    }

    @Test func unsentChangesOutliveADeleteFromAnotherDevice() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        let edited = Note(id: note.id, title: "Edited")
        try container.save(our: edited, zone: "Notes")
        try container.save(deleted: note.id)

        let row = try #require(try container.row(id: note.id))
        let ours = try JSONRepresentation(edited)
        #expect(row == RecordContainer.Row(id: note.id, zone: "Notes", type: "Note", ours: ours))
        #expect(row.status == .waitingToUpload)
    }

    @Test func deletingOurRecordFindsItsRowByItsID() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.delete(our: note)
        #expect(try container.row(id: note.id)?.isDeleted == true)

        try container.save(our: Page(slug: "intro"), id: \.slug, zone: "Notes")
        try container.delete(our: Page(slug: "intro", title: "Changed"), id: \.slug)
        #expect(try container.row(id: RecordContainer.recordID(for: "intro", type: "Page")) == nil)
    }
}

private struct Page: Codable {
    var slug: String
    var title = ""
}
