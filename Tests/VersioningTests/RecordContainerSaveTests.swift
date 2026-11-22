import Foundation
import Testing
@testable import Versioning

private struct Note: Codable, Identifiable {
    var id = UUID()
    var title: String
}

private struct Page: Codable, Identifiable {
    var id: String
    var title = ""
}

private struct Chapter: Codable, Identifiable {
    var id: String
}

@Suite struct RecordContainerSaveTests {
    @Test func aUUIDIDIsTheRecordID() throws {
        let note = Note(title: "Draft")
        #expect(try RecordContainer.recordID(of: note) == note.id)
    }

    @Test func anyOtherIDHashesWithItsType() throws {
        let id = try RecordContainer.recordID(of: Page(id: "intro"))
        #expect(try RecordContainer.recordID(of: Page(id: "intro", title: "Changed")) == id)
        #expect(try RecordContainer.recordID(of: Page(id: "outro")) != id)
        #expect(try RecordContainer.recordID(of: Chapter(id: "intro")) != id)
        #expect(id == UUID(stableHashOf: #"Page|"intro""#))
    }

    @Test func aRecordWithAnotherIDSavesUnderItsHash() throws {
        let container = RecordContainer()
        try container.save(our: Page(id: "intro", title: "First"), zone: "Notes")
        try container.save(our: Page(id: "intro", title: "Second"), zone: "Notes")

        let row = try #require(try container.row(id: RecordContainer.recordID(of: Page(id: "intro"))))
        #expect(row.ours == ["id": "intro", "title": "Second"])
    }

    @Test func aNewRecordIsWaitingToUpload() throws {
        let container = RecordContainer()
        let note = Note(title: "Draft")
        try container.save(our: note, zone: "Notes")

        let row = try #require(try container.row(id: note.id))
        #expect(row == RecordContainer.Row(id: note.id, zone: "Notes", type: "Note", ours: ["id": .string(note.id.uuidString), "title": "Draft"]))
        #expect(row.status == .waitingToUpload)
    }

    @Test func savingAgainReplacesOursAndKeepsTheRest() throws {
        let container = RecordContainer()
        var note = Note(title: "First")
        try container.save(our: note, zone: "Notes")
        try container.execute("UPDATE record SET base = '{\"title\":\"Base\"}', is_deleted = 1, error = 'Record too large'")

        note.title = "Second"
        try container.save(our: note, zone: "Elsewhere", owner: "someone")

        let row = try #require(try container.row(id: note.id))
        #expect(row.ours?["title"] == "Second")
        #expect(row.base == ["title": "Base"])
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
        #expect(try RecordContainer(url: url).row(id: note.id)?.ours?["title"] == "Kept")
    }
}
