import Foundation
import Testing
@testable import Versioning

private struct Note: Codable, Equatable, Sendable {
    var title = "Title"
    var body = "Body"
    var tags: Set<String> = ["a", "b"]
    var scores: [String: Int] = ["x": 1, "y": 2]
    var lines = ["one", "two", "three"]
    var pinned: Bool?
    var place = Place()
}

private struct Place: Codable, Equatable, Sendable {
    var city = "Oslo"
    var floor = 1
}

/// Merges through JSON, and decodes the result.
private func merge(_ ours: Note, _ theirs: Note, base: Note?) throws -> (merged: Note, conflicts: [JSONRepresentation.Path]) {
    let schema = try JSONSchema(for: Note.self)
    let original = try base.map { try JSONRepresentation($0) }
    let (merged, conflicts) = try JSONRepresentation(ours).merging(JSONRepresentation(theirs), base: original, under: schema)
    return (try merged.decode(), conflicts)
}

@Suite struct JSONRepresentationMergingTests {
    @Test func changesFromEachSideBothApply() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.title = "Ours"
        theirs.body = "Theirs"
        theirs.place.floor = 3
        let (merged, conflicts) = try merge(ours, theirs, base: base)
        #expect(conflicts.isEmpty)
        #expect(merged.title == "Ours")
        #expect(merged.body == "Theirs")
        #expect(merged.place == Place(city: "Oslo", floor: 3))
    }

    @Test func bothChangingAValueDifferentlyConflictsAndKeepsOurs() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.place.city = "Bergen"
        theirs.place.city = "Tromsø"
        theirs.title = "Theirs"
        let (merged, conflicts) = try merge(ours, theirs, base: base)
        #expect(conflicts == [["place", "city"]])
        #expect(merged.place.city == "Bergen")
        #expect(merged.title == "Theirs", "Changes that do not conflict still apply.")
    }

    @Test func bothMakingTheSameChangeMerges() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.title = "Same"
        theirs.title = "Same"
        let (merged, conflicts) = try merge(ours, theirs, base: base)
        #expect(conflicts.isEmpty)
        #expect(merged.title == "Same")
    }

    @Test func aSetMergesByMembership() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.tags = ["a", "b", "c"]
        theirs.tags = ["b", "d"]
        let (merged, conflicts) = try merge(ours, theirs, base: base)
        #expect(conflicts.isEmpty)
        #expect(merged.tags == ["b", "c", "d"])
    }

    @Test func aDictionaryMergesKeyByKey() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.scores["x"] = 5
        theirs.scores["z"] = 3
        theirs.scores["y"] = nil
        let (merged, conflicts) = try merge(ours, theirs, base: base)
        #expect(conflicts.isEmpty)
        #expect(merged.scores == ["x": 5, "z": 3])
    }

    @Test func removingAKeyTheOtherSideChangedConflicts() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.scores["x"] = nil
        theirs.scores["x"] = 9
        let (merged, conflicts) = try merge(ours, theirs, base: base)
        #expect(conflicts == [["scores", "x"]])
        #expect(merged.scores == ["y": 2], "Ours, without the key, is kept.")
    }

    @Test func anArrayMergesElementByElement() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.lines.append("four")
        theirs.lines.insert("zero", at: 0)
        let (merged, conflicts) = try merge(ours, theirs, base: base)
        #expect(conflicts.isEmpty)
        #expect(merged.lines == ["zero", "one", "two", "three", "four"])
    }

    @Test func anArrayThatCannotMergeConflictsAsAWhole() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.lines[1] = "ours"
        theirs.lines[1] = "theirs"
        let (merged, conflicts) = try merge(ours, theirs, base: base)
        #expect(conflicts == [["lines"]])
        #expect(merged.lines == ours.lines)
    }

    @Test func aMissingOptionalCountsAsNull() throws {
        let base = Note()
        var theirs = base
        theirs.pinned = true
        let schema = try JSONSchema(for: Note.self)
        var json = try JSONRepresentation(base)
        json[["pinned"]] = .null  // Ours writes null where the base leaves the key out.
        let (merged, conflicts) = try json.merging(JSONRepresentation(theirs), base: JSONRepresentation(base), under: schema)
        #expect(conflicts.isEmpty)
        #expect(try merged.decode(Note.self).pinned == true)
    }

    @Test func withoutABaseOnlySharedValuesMerge() throws {
        var ours = Note(), theirs = Note()
        ours.tags = ["b", "a"]
        theirs.tags = ["a", "b"]
        var (merged, conflicts) = try merge(ours, theirs, base: nil)
        #expect(conflicts.isEmpty)
        #expect(merged == ours)

        theirs.title = "Theirs"
        theirs.place.floor = 2
        (merged, conflicts) = try merge(ours, theirs, base: nil)
        #expect(conflicts == [["title"], ["place", "floor"]])
        #expect(merged == ours)
    }

    @Test func undeclaredKeysAndPlainJSONMergeByShape() {
        let base: JSONRepresentation = ["kept": 1, "extra": ["a": 1, "b": 1]]
        let ours: JSONRepresentation = ["kept": 1, "extra": ["a": 2, "b": 1]]
        let theirs: JSONRepresentation = ["kept": 1, "extra": ["a": 1, "b": 3]]
        let (merged, conflicts) = ours.merging(theirs, base: base, under: .object([("kept", .integer())]))
        #expect(conflicts.isEmpty)
        #expect(merged == ["kept": 1, "extra": ["a": 2, "b": 3]])
    }
}

@Suite struct PropertyMergeTests {
    @Test func mergesWhatDoesNotConflict() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.title = "Ours"
        theirs.tags.insert("c")
        let merged = try PropertyMerge<Note>().merge(base: base, ours: ours, theirs: theirs)
        #expect(merged.title == "Ours")
        #expect(merged.tags == ["a", "b", "c"])
    }

    @Test func throwsOnAConflictWithoutASide() {
        let base = Note()
        var ours = base, theirs = base
        ours.title = "Ours"
        theirs.title = "Theirs"
        #expect(throws: MergeConflict.self) { try PropertyMerge<Note>().merge(base: base, ours: ours, theirs: theirs) }
    }

    @Test func keepsTheNamedSideAtEachConflict() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.title = "Ours"
        theirs.title = "Theirs"
        ours.body = "Ours"
        theirs.place.floor = 4
        let favoringTheirs = try PropertyMerge<Note>(favoring: .theirs).merge(base: base, ours: ours, theirs: theirs)
        #expect(favoringTheirs.title == "Theirs")
        #expect(favoringTheirs.body == "Ours")
        #expect(favoringTheirs.place.floor == 4)
        let favoringOurs = try PropertyMerge<Note>(favoring: .ours).merge(base: base, ours: ours, theirs: theirs)
        #expect(favoringOurs.title == "Ours")
        #expect(favoringOurs.place.floor == 4)
    }

    @Test func aRemovalTheOtherSideChangedTakesTheNamedSide() throws {
        let base = Note()
        var ours = base, theirs = base
        ours.scores["x"] = nil
        theirs.scores["x"] = 9
        let merged = try PropertyMerge<Note>(favoring: .theirs).merge(base: base, ours: ours, theirs: theirs)
        #expect(merged.scores == ["x": 9, "y": 2])
    }

    @Test func withoutABaseEqualValuesMerge() throws {
        let note = Note()
        #expect(try PropertyMerge<Note>().merge(ours: note, theirs: note) == note)
        var theirs = note
        theirs.title = "Theirs"
        #expect(throws: MergeConflict.self) { try PropertyMerge<Note>().merge(ours: note, theirs: theirs) }
        #expect(try PropertyMerge<Note>(favoring: .theirs).merge(ours: note, theirs: theirs) == theirs)
    }
}

private struct Views: RawRepresentable, Codable, Equatable, Mergeable {
    var rawValue: Int

    func merging(with theirs: Views, from base: Views) throws(MergeConflict) -> Views {
        try merging(with: theirs, from: base, using: .rawValue(.sum()))
    }
}

/// A type whose own merge always conflicts.
private struct Stamp: Codable, Equatable, Mergeable {
    var value = 0

    func merging(with theirs: Stamp, from base: Stamp) throws(MergeConflict) -> Stamp {
        throw MergeConflict()
    }
}

private struct Venue: Codable, Equatable {
    var city = "Oslo"
    var visits = Views(rawValue: 0)
}

private struct Post: Codable, Equatable, Mergeable {
    var title = "Title"
    var views = Views(rawValue: 3)
    var venue = Venue()
    var stamp = Stamp()
    var counts: [String: Views] = ["a": Views(rawValue: 1)]
}

@Suite struct DefaultMergeTests {
    @Test func propertyMergeReadsOnlyTheShape() throws {
        let base = Post()
        var ours = base, theirs = base
        ours.views = Views(rawValue: 5)
        theirs.views = Views(rawValue: 4)
        #expect(throws: MergeConflict.self) { try PropertyMerge<Post>().merge(base: base, ours: ours, theirs: theirs) }
        #expect(try ours.merging(with: theirs, from: base, using: .byProperty(favoring: .theirs)).views == Views(rawValue: 4))
        #expect(try ours.merging(with: theirs, from: base, using: .default(favoring: .theirs)).views == Views(rawValue: 6))
    }

    @Test func aMergeablePropertyMergesByItsOwnType() throws {
        let base = Post()
        var ours = base, theirs = base
        ours.views = Views(rawValue: 5)
        theirs.views = Views(rawValue: 4)
        ours.title = "Ours"
        let merged = try ours.merging(with: theirs, from: base)
        #expect(merged.views == Views(rawValue: 6))
        #expect(merged.title == "Ours")
    }

    @Test func aNestedMergeablePropertyMergesByItsOwnType() throws {
        let base = Post()
        var ours = base, theirs = base
        ours.venue.visits = Views(rawValue: 2)
        theirs.venue.visits = Views(rawValue: 3)
        theirs.venue.city = "Bergen"
        let merged = try DefaultMerge<Post>().merge(base: base, ours: ours, theirs: theirs)
        #expect(merged.venue == Venue(city: "Bergen", visits: Views(rawValue: 5)))
    }

    @Test func aDictionaryOfMergeableValuesMergesEachByItsOwnType() throws {
        let base = Post()
        var ours = base, theirs = base
        ours.counts["a"] = Views(rawValue: 2)
        theirs.counts["a"] = Views(rawValue: 4)
        #expect(try ours.merging(with: theirs, from: base).counts == ["a": Views(rawValue: 5)])
    }

    @Test func otherConflictsStillThrowOrTakeTheFavoredSide() throws {
        let base = Post()
        var ours = base, theirs = base
        ours.views = Views(rawValue: 5)
        theirs.views = Views(rawValue: 4)
        ours.title = "Ours"
        theirs.title = "Theirs"
        #expect(throws: MergeConflict.self) { try DefaultMerge<Post>().merge(base: base, ours: ours, theirs: theirs) }
        let merged = try DefaultMerge<Post>(favoring: .theirs).merge(base: base, ours: ours, theirs: theirs)
        #expect(merged.title == "Theirs")
        #expect(merged.views == Views(rawValue: 6))
    }

    @Test func aMergeablePropertysConflictThrowsOrTakesTheFavoredSide() throws {
        let base = Post()
        var ours = base, theirs = base
        ours.stamp.value = 1
        theirs.stamp.value = 2
        #expect(throws: MergeConflict.self) { try ours.merging(with: theirs, from: base) }
        #expect(try DefaultMerge<Post>(favoring: .theirs).merge(base: base, ours: ours, theirs: theirs).stamp.value == 2)
        #expect(try DefaultMerge<Post>(favoring: .ours).merge(base: base, ours: ours, theirs: theirs).stamp.value == 1)
    }

    @Test func aPropertyOnlyOneSideChangedSkipsItsOwnMerge() throws {
        let base = Post()
        var ours = base
        ours.stamp.value = 1
        #expect(try ours.merging(with: base, from: base).stamp.value == 1, "Stamp's merge would conflict.")
    }
}
