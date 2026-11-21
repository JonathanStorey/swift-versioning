import Foundation
import Testing
@testable import Versioning

private struct Note: Codable, Identifiable {
    var id = UUID()
    var title: String
}

@Suite struct RecordContainerSaveTests {
    @Test func aNewRecordIsWaitingToUpload() throws {
        let container = RecordContainer()
        let note = Note(title: "Draft")
        try container.save(our: note, zone: "Notes")

        let row = try #require(try container.row(id: note.id))
        #expect(row == RecordContainer.Row(id: note.id, zone: "Notes", type: "Note", ours: ["id": .string(note.id.uuidString), "title": .string("Draft")]))
        #expect(row.status == .waitingToUpload)
    }

    @Test func savingAgainReplacesOursAndKeepsTheRest() throws {
        let container = RecordContainer()
        var note = Note(title: "First")
        try container.save(our: note, zone: "Notes")
        try container.execute("UPDATE record SET base = '{\"title\":{\"string\":\"Base\"}}', is_deleted = 1, error = 'Record too large'")

        note.title = "Second"
        try container.save(our: note, zone: "Elsewhere", owner: "someone")

        let row = try #require(try container.row(id: note.id))
        #expect(row.ours?["title"] == .string("Second"))
        #expect(row.base == ["title": .string("Base")])
        #expect(row.zone == "Notes", "A record never moves zones.")
        #expect(row.owner == "__defaultOwner__")
        #expect(!row.isDeleted)
        #expect(row.error == nil)
    }

    @Test func anUnknownIdHasNoRow() throws {
        #expect(try RecordContainer().row(id: UUID()) == nil)
    }

    @Test func aFileContainerKeepsItsRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let note = Note(title: "Kept")
        try RecordContainer(url: url).save(our: note, zone: "Notes")
        #expect(try RecordContainer(url: url).row(id: note.id)?.ours?["title"] == .string("Kept"))
    }
}
