import Foundation
import Testing
@testable import Versioning

private func at(_ seconds: TimeInterval, latitude: Double = 1) -> RecordRepresentation.Field {
    .location(Location(latitude: latitude, longitude: 2, timestamp: Date(timeIntervalSinceReferenceDate: seconds)))
}

private func asset(containing text: String) throws -> RecordRepresentation.Field {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(text.utf8).write(to: url)
    return .asset(url)
}

@Suite struct FieldMergeTests {
    @Test func theSideThatChangedAFieldWins() throws {
        let base = RecordRepresentation.Field.string("Base")
        #expect(try RecordRepresentation.Field.string("Ours").merging(with: base, from: base) == .string("Ours"))
        #expect(try base.merging(with: .string("Theirs"), from: base) == .string("Theirs"))
        #expect(try RecordRepresentation.Field.string("Same").merging(with: .string("Same"), from: base) == .string("Same"))
    }

    @Test func differentChangesToAPlainFieldConflict() {
        #expect(throws: MergeConflict()) {
            try RecordRepresentation.Field.int64(5).merging(with: .int64(4), from: .int64(3))
        }
        #expect(throws: MergeConflict()) {
            try RecordRepresentation.Field.string("Ours").merging(with: .int64(4), from: .string("Base"))
        }
    }

    @Test func aLocationKeepsTheLaterMeasurement() throws {
        #expect(try at(20).merging(with: at(10, latitude: 5), from: at(0)) == at(20))
        #expect(try at(10).merging(with: at(20, latitude: 5)) == at(20, latitude: 5))
    }

    @Test func assetsWithTheSameBytesDoNotConflict() throws {
        let ours = try asset(containing: "same")
        #expect(try ours.merging(with: asset(containing: "same"), from: asset(containing: "base")) == ours)
        #expect(throws: MergeConflict()) {
            try asset(containing: "ours").merging(with: asset(containing: "theirs"), from: asset(containing: "base"))
        }
    }

    @Test func aListKeepsEverySidesAdditions() throws {
        let a = RecordRepresentation.Field.reference(.init(recordName: "A"))
        let b = RecordRepresentation.Field.reference(.init(recordName: "B"))
        let c = RecordRepresentation.Field.reference(.init(recordName: "C"))
        #expect(try RecordRepresentation.Field.list([c, a]).merging(with: .list([a, b]), from: .list([a])) == .list([c, a, b]))
    }

    @Test func anEncryptedFieldMergesWhatItHolds() throws {
        #expect(try RecordRepresentation.Field.encrypted(at(20)).merging(with: .encrypted(at(10, latitude: 5)), from: .encrypted(at(0))) == .encrypted(at(20)))
        #expect(throws: MergeConflict()) {
            try RecordRepresentation.Field.encrypted(.int64(5)).merging(with: .encrypted(.int64(4)), from: .encrypted(.int64(3)))
        }
    }

    @Test func fieldsMergeKeyByKey() throws {
        let base: [String: RecordRepresentation.Field] = ["title": .string("Base"), "count": .int64(1), "place": at(0), "old": .string("Gone")]
        let ours: [String: RecordRepresentation.Field] = ["title": .string("Ours"), "count": .int64(1), "place": at(20), "new": .double(1.5)]
        let theirs: [String: RecordRepresentation.Field] = ["title": .string("Base"), "count": .int64(2), "place": at(10, latitude: 5), "old": .string("Gone")]
        #expect(try ours.merging(with: theirs, from: base) == ["title": .string("Ours"), "count": .int64(2), "place": at(20), "new": .double(1.5)])
    }

    @Test func aConflictNamesEveryFieldThatCouldNotMerge() {
        let base: [String: RecordRepresentation.Field] = ["title": .string("Base"), "count": .int64(1), "body": .string("Base")]
        let ours: [String: RecordRepresentation.Field] = ["title": .string("Ours"), "count": .int64(3), "body": .string("Base")]
        let theirs: [String: RecordRepresentation.Field] = ["title": .string("Theirs"), "count": .int64(2), "body": .string("Theirs")]
        #expect(throws: MergeConflict(at: [["count"], ["title"]])) { try ours.merging(with: theirs, from: base) }
    }
}
