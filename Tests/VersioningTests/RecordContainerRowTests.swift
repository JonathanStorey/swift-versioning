import Foundation
import Testing
@testable import Versioning

@Suite struct RecordContainerRowTests {
    private let row = RecordContainer.Row(id: UUID(), zone: "Notes", type: "Note", base: ["title": .string("Base")])

    @Test func aRowWithNothingWaitingIsSynced() {
        #expect(row.status == .synced)
        #expect(row.owner == "__defaultOwner__")
    }

    @Test func savedChangesAndDeletesWaitToUpload() {
        var changed = row
        changed.ours = ["title": .string("Ours")]
        #expect(changed.status == .waitingToUpload)

        var deleted = row
        deleted.isDeleted = true
        #expect(deleted.status == .waitingToUpload)
    }

    @Test func anErrorWithoutTheirsIsARejectedUpload() {
        var rejected = row
        rejected.ours = ["title": .string("Ours")]
        rejected.error = "Record too large"
        #expect(rejected.status == .rejected("Record too large"))
    }

    @Test func theirsOutranksEverythingElse() {
        var waiting = row
        waiting.ours = ["title": .string("Ours")]
        waiting.isDeleted = true
        waiting.theirs = ["title": .string("Theirs")]
        #expect(waiting.status == .waitingToMerge)

        waiting.error = "title changed on both sides"
        #expect(waiting.status == .conflict("title changed on both sides"))
    }
}
