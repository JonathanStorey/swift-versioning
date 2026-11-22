import Foundation
import Testing
@testable import Versioning

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title: String
}

/// A plain struct, identified by `slug`.
private struct Page: Codable, Mergeable {
    var slug: String
    var title = ""
}

private struct Chapter: Codable, Mergeable {
    var slug: String
}

private extension RecordContainer {
    static func registered() -> RecordContainer {
        let container = RecordContainer()
        container.register(Note.self)
        container.register(Page.self, id: \.slug)
        container.register(Chapter.self, id: \.slug)
        return container
    }
}

@Suite struct RecordContainerSaveTests {
    @Test func aUUIDIDIsTheRecordID() throws {
        let note = Note(title: "Draft")
        #expect(try RecordContainer.registered().recordID(of: note) == note.id)
    }

    @Test func anyOtherIDHashesWithItsType() throws {
        let container = RecordContainer.registered()
        let id = try container.recordID(of: Page(slug: "intro"))
        #expect(try container.recordID(of: Page(slug: "intro", title: "Changed")) == id)
        #expect(try container.recordID(of: Page(slug: "outro")) != id)
        #expect(try container.recordID(of: Chapter(slug: "intro")) != id)
        #expect(id == UUID(stableHashOf: #"Page|"intro""#))
    }

    @Test func aPlainStructSavesUnderTheHashOfItsRegisteredID() throws {
        let container = RecordContainer.registered()
        try container.save(our: Page(slug: "intro", title: "First"), zone: "Notes")
        try container.save(our: Page(slug: "intro", title: "Second"), zone: "Notes")

        let row = try #require(try container.row(id: container.recordID(of: Page(slug: "intro"))))
        #expect(row.ours == ["slug": "intro", "title": "Second"])
    }

    @Test func anUnregisteredTypeCannotSave() {
        #expect(throws: DecodingError.self) { try RecordContainer().save(our: Note(title: "Draft"), zone: "Notes") }
    }

    @Test func aNewRecordIsWaitingToUpload() throws {
        let container = RecordContainer.registered()
        let note = Note(title: "Draft")
        try container.save(our: note, zone: "Notes")

        let row = try #require(try container.row(id: note.id))
        #expect(row == RecordContainer.Row(id: note.id, zone: "Notes", type: "Note", ours: ["id": .string(note.id.uuidString), "title": "Draft"]))
        #expect(row.status == .waitingToUpload)
    }

    @Test func savingAgainReplacesOursAndKeepsTheRest() throws {
        let container = RecordContainer.registered()
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
        let container = try RecordContainer(url: url)
        container.register(Note.self)
        try container.save(our: note, zone: "Notes")
        #expect(try RecordContainer(url: url).row(id: note.id)?.ours?["title"] == "Kept")
    }
}
