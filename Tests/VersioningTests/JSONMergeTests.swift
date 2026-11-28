import Foundation
import Testing
@testable import Versioning

private struct Entry: Codable, Identifiable, Equatable {
    var id: Int
    var text: String
}

private struct Note: Codable, Equatable {
    var title: String
    var tags: Set<String>
    var entries: [Entry]
}

/// A counter that merges by adding both sides' changes.
private struct Views: RawRepresentable, Codable, Equatable, Mergeable {
    var rawValue: Int

    func merging(with theirs: Views, from base: Views) throws(MergeConflict) -> Views {
        try merging(with: theirs, from: base, using: .rawValue(.sum()))
    }
}

private struct Card: Codable, Equatable {
    var id: String
    var views: Views
}

private struct Board: Codable, Equatable {
    var title: String
    var views: Views
    var tasks: [Card]
    var counts: [String: Views]
}

/// A type that merges as a whole, by keeping the longer text.
private struct Longest: Codable, Equatable, Mergeable {
    var text: String

    func merging(with theirs: Longest, from base: Longest) throws(MergeConflict) -> Longest {
        text.count >= theirs.text.count ? self : theirs
    }
}

/// An element whose `id` is encoded as `"uuid"`.
private struct Tagged: Codable, Identifiable, Equatable {
    var id: String
    var text: String

    enum CodingKeys: String, CodingKey {
        case id = "uuid"
        case text
    }
}

private struct Shelf: Codable {
    var items: [Tagged]
}

private let noteSchema = try! JSONSchema(for: Note.self)

/// Merges three notes and decodes the result.
private func merge(
    base: Note, ours: Note, theirs: Note, favoring: KeepMerge<JSONRepresentation> = .ours, schema: JSONSchema? = noteSchema
) throws -> (merged: Note, conflicts: [JSONRepresentation.Path]) {
    let result = try DefaultMerge<JSONRepresentation>(favoring: favoring, using: schema)
        .merged(JSONRepresentation(ours), JSONRepresentation(theirs), base: JSONRepresentation(base))
    return (try result.merged.decode(Note.self), result.conflicts)
}

private func json(_ text: String) throws -> JSONRepresentation {
    try JSONDecoder().decode(JSONRepresentation.self, from: Data(text.utf8))
}

struct JSONMergeTests {
    fileprivate let base = Note(title: "Plan", tags: ["home"], entries: [Entry(id: 1, text: "one"), Entry(id: 2, text: "two")])

    @Test func keepsChangesFromBothSides() throws {
        var ours = base, theirs = base
        ours.title = "Weekend plan"
        theirs.tags.insert("garden")
        let result = try merge(base: base, ours: ours, theirs: theirs)
        #expect(result.merged.title == "Weekend plan")
        #expect(result.merged.tags == ["home", "garden"])
        #expect(result.conflicts.isEmpty)
    }

    @Test func conflictsTakeTheFavoredSide() throws {
        var ours = base, theirs = base
        ours.title = "Ours"
        theirs.title = "Theirs"
        let favoringOurs = try merge(base: base, ours: ours, theirs: theirs, favoring: .ours)
        let favoringTheirs = try merge(base: base, ours: ours, theirs: theirs, favoring: .theirs)
        #expect(favoringOurs.merged.title == "Ours")
        #expect(favoringTheirs.merged.title == "Theirs")
        #expect(favoringOurs.conflicts == [["title"]])
    }

    @Test func mergesSetsByMembership() throws {
        var ours = base, theirs = base
        ours.tags = ["work"]
        theirs.tags = ["home", "garden"]
        #expect(try merge(base: base, ours: ours, theirs: theirs).merged.tags == ["work", "garden"])
    }

    @Test func mergesIdentifiedArraysByID() throws {
        var ours = base, theirs = base
        ours.entries = [Entry(id: 2, text: "two"), Entry(id: 1, text: "one, edited by us")]
        theirs.entries = [Entry(id: 1, text: "one"), Entry(id: 2, text: "two, edited by them"), Entry(id: 3, text: "three")]
        let result = try merge(base: base, ours: ours, theirs: theirs)
        let texts = Dictionary(uniqueKeysWithValues: result.merged.entries.map { ($0.id, $0.text) })
        #expect(texts == [1: "one, edited by us", 2: "two, edited by them", 3: "three"])
        #expect(result.conflicts.isEmpty)
    }

    @Test func removalBeatsAnUnchangedElement() throws {
        var ours = base, theirs = base
        ours.entries = [Entry(id: 2, text: "two"), Entry(id: 1, text: "one, edited by us")]
        theirs.entries = [Entry(id: 1, text: "one")]
        let result = try merge(base: base, ours: ours, theirs: theirs)
        #expect(result.merged.entries == [Entry(id: 1, text: "one, edited by us")])
    }

    @Test func infersSchemaWhenNoneGiven() throws {
        var ours = base, theirs = base
        ours.title = "Ours"
        ours.entries = [Entry(id: 2, text: "two"), Entry(id: 1, text: "one, edited by us")]
        theirs.title = "Theirs"
        theirs.entries = [Entry(id: 1, text: "one"), Entry(id: 2, text: "two, edited by them"), Entry(id: 3, text: "three")]
        let result = try merge(base: base, ours: ours, theirs: theirs, favoring: .theirs, schema: nil)
        let texts = Dictionary(uniqueKeysWithValues: result.merged.entries.map { ($0.id, $0.text) })
        #expect(result.merged.title == "Theirs")
        #expect(texts == [1: "one, edited by us", 2: "two, edited by them", 3: "three"])
        #expect(result.conflicts == [["title"]])
    }

    @Test func infersOptionalsAndNumbers() {
        let schema = JSONSchema(inferredFrom: [["count": 1, "note": nil], ["count": 2.5]])
        #expect(schema == .object([(key: "count", value: .number), (key: "note", value: .optional(.null))]))
    }

    @Test func isAMergeStrategy() throws {
        let merged = try DefaultMerge<JSONRepresentation>(favoring: .theirs)
            .merge(base: ["a": 1, "b": 1], ours: ["a": 2, "b": 1], theirs: ["a": 3, "b": 2])
        #expect(merged == ["a": 3, "b": 2])
        let dotSyntax: DefaultMerge<JSONRepresentation> = .default(favoring: .ours)
        #expect(try dotSyntax.merge(base: ["a": 1], ours: ["a": 2], theirs: ["a": 3]) == ["a": 2])
    }

    @Test func withoutAFavoredSideConflictsThrow() {
        do {
            _ = try DefaultMerge<JSONRepresentation>().merge(base: ["a": 1, "b": 1], ours: ["a": 2, "b": 1], theirs: ["a": 3, "b": 1])
            Issue.record("The conflict at a did not throw.")
        } catch {
            #expect(error.paths == [["a"]])
        }
    }

    @Test func identifiedElementsMatchByTheirEncodedID() throws {
        let base: JSONRepresentation = ["items": [["uuid": "a", "text": "one"], ["uuid": "b", "text": "two"]]]
        let ours: JSONRepresentation = ["items": [["uuid": "b", "text": "two"], ["uuid": "a", "text": "one, ours"]]]
        let theirs: JSONRepresentation = ["items": [["uuid": "a", "text": "one"], ["uuid": "b", "text": "two, theirs"], ["uuid": "c", "text": "three"]]]
        let result = DefaultMerge<JSONRepresentation>(for: Shelf.self).merged(ours, theirs, base: base)
        let texts = try result.merged.decode(Shelf.self).items.map(\.text)
        #expect(Set(texts) == ["one, ours", "two, theirs", "three"])
        #expect(result.conflicts.isEmpty)
    }

    // MARK: Mergeable values

    @Test func mergeableValuesMergeByTheirOwnRules() throws {
        let merge = DefaultMerge<JSONRepresentation>(for: Board.self)
        let base = try json(#"{"title":"A","views":10,"tasks":[{"id":"t","views":1}],"counts":{"x":5}}"#)
        let ours = try json(#"{"title":"A","views":12,"tasks":[{"id":"t","views":2}],"counts":{"x":6}}"#)
        let theirs = try json(#"{"title":"A","views":15,"tasks":[{"id":"t","views":4}],"counts":{"x":9}}"#)
        let result = merge.merged(ours, theirs, base: base)
        #expect(try result.merged == json(#"{"title":"A","views":17,"tasks":[{"id":"t","views":5}],"counts":{"x":10}}"#))
        #expect(result.conflicts.isEmpty)
    }

    @Test func sameChangeOnBothSidesStillMerges() throws {
        let merge = DefaultMerge<JSONRepresentation>(for: Board.self)
        let base = try json(#"{"title":"A","views":10,"tasks":[],"counts":{}}"#)
        let raised = try json(#"{"title":"A","views":11,"tasks":[],"counts":{}}"#)
        #expect(merge.merged(raised, raised, base: base).merged["views"] == 12)
    }

    @Test func mergeableValuesMergeInJSONTheTypeCannotRead() throws {
        let merge = DefaultMerge<JSONRepresentation>(favoring: .theirs, for: Board.self)
        // A newer version renamed `tasks` and added a key, so neither side decodes as `Board`.
        let base = try json(#"{"title":"A","views":10,"items":[]}"#)
        let ours = try json(#"{"title":"Ours","views":12,"items":[]}"#)
        let theirs = try json(#"{"title":"Theirs","views":15,"items":[],"new":true}"#)
        let result = merge.merged(ours, theirs, base: base)
        #expect(try result.merged == json(#"{"title":"Theirs","views":17,"items":[],"new":true}"#))
        #expect(result.conflicts == [["title"]])
    }

    @Test func identifiedElementsPairByIDWhenReordered() throws {
        let merge = DefaultMerge<JSONRepresentation>(for: Board.self)
        let base = try json(#"{"title":"A","views":0,"tasks":[{"id":"a","views":1},{"id":"b","views":1}],"counts":{}}"#)
        let ours = try json(#"{"title":"A","views":0,"tasks":[{"id":"b","views":2},{"id":"a","views":1}],"counts":{}}"#)
        let theirs = try json(#"{"title":"A","views":0,"tasks":[{"id":"a","views":1},{"id":"b","views":3}],"counts":{}}"#)
        let merged = merge.merged(ours, theirs, base: base).merged
        let views = merged["tasks"]?.elements?.first { $0["id"] == "b" }?["views"]
        #expect(views == 4)
    }

    @Test func aMergeableTypeMergesAsAWhole() throws {
        let merge = DefaultMerge<JSONRepresentation>(favoring: .ours, for: Longest.self)
        let result = merge.merged(["text": "ours"], ["text": "theirs, longer"], base: ["text": "base"])
        #expect(result.merged == ["text": "theirs, longer"])
        #expect(result.conflicts.isEmpty)
    }

    @Test func withoutABaseMergeableValuesUseTheirTwoWayMerge() throws {
        let merge = DefaultMerge<JSONRepresentation>(favoring: .ours, for: Board.self)
        let ours = try json(#"{"title":"A","views":12,"tasks":[],"counts":{}}"#)
        let theirs = try json(#"{"title":"A","views":15,"tasks":[],"counts":{}}"#)
        // `Views` has no merge without a base, so the conflict keeps ours.
        let result = merge.merged(ours, theirs, base: nil)
        #expect(result.merged["views"] == 12)
        #expect(result.conflicts == [["views"]])
    }
}

private extension JSONRepresentation {
    var elements: [JSONRepresentation]? {
        if case .array(let elements) = self { elements } else { nil }
    }
}
