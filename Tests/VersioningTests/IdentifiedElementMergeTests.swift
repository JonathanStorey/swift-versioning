import Foundation
import Testing
@testable import Versioning

private struct Item: Identifiable, Codable, Equatable, Hashable {
    var id: Int
    var title: String
    var done = false
}

/// An element whose own merge sums its count.
private struct Tally: Identifiable, Codable, Equatable, Hashable, Mergeable {
    var id: Int
    var count: Int

    func merging(with theirs: Tally, from base: Tally) throws(MergeConflict) -> Tally {
        Tally(id: id, count: count + theirs.count - base.count)
    }
}

private struct Board: Codable, Equatable, Mergeable {
    var items: [Item] = [Item(id: 1, title: "a"), Item(id: 2, title: "b")]
    var tallies: [Tally] = [Tally(id: 1, count: 3)]
    var tagged: Set<Item> = [Item(id: 1, title: "a")]
    var byCode: [Code: Tally] = [Code(value: 1): Tally(id: 1, count: 3)]
}

/// A key `JSONEncoder` writes as part of a flat array of keys and values.
private struct Code: Hashable, Codable {
    var value: Int
}

private let a = Item(id: 1, title: "a"), b = Item(id: 2, title: "b")

@Suite struct IdentifiedElementMergeTests {
    @Test func elementsMergeByIDWhereverTheyMoved() throws {
        var mine = a
        mine.done = true
        var yours = a
        yours.title = "A"
        let merged = try IdentifiedElementMerge<Item>().merge(base: [a, b], ours: [b, mine], theirs: [yours, b])
        #expect(merged == [b, Item(id: 1, title: "A", done: true)])
    }

    @Test func additionsFromBothSidesAreKeptInPlace() throws {
        let c = Item(id: 3, title: "c"), d = Item(id: 4, title: "d")
        let merged = try IdentifiedElementMerge<Item>().merge(base: [a, b], ours: [a, b, c], theirs: [a, d, b])
        #expect(merged == [a, d, b, c])
    }

    @Test func aRemovalStandsUnlessTheOtherSideChangedTheElement() throws {
        #expect(try IdentifiedElementMerge<Item>().merge(base: [a, b], ours: [a, b], theirs: [a]) == [a])
        var changed = b
        changed.done = true
        #expect(throws: MergeConflict.self) { try IdentifiedElementMerge<Item>().merge(base: [a, b], ours: [a, changed], theirs: [a]) }
        #expect(try IdentifiedElementMerge<Item>(favoring: .ours).merge(base: [a, b], ours: [a, changed], theirs: [a]) == [a, changed])
        #expect(try IdentifiedElementMerge<Item>(favoring: .theirs).merge(base: [a, b], ours: [a, changed], theirs: [a]) == [a])
    }

    @Test func anElementBothChangedAlikeConflictsOrTakesTheFavoredSide() throws {
        var mine = a, yours = a
        mine.title = "Mine"
        yours.title = "Yours"
        #expect(throws: MergeConflict.self) { try merged([a], [mine], [yours], using: .byID()) }
        #expect(try merged([a], [mine], [yours], using: .byID(favoring: .theirs)) == [yours])
    }

    @Test func aMergeableElementMergesByItsOwnMerge() throws {
        let base = [Tally(id: 1, count: 3)]
        #expect(try merged(base, [Tally(id: 1, count: 5)], [Tally(id: 1, count: 4)], using: .byID()) == [Tally(id: 1, count: 6)])
    }

    @Test func onlyTheirsReorderingTakesTheirOrder() throws {
        let c = Item(id: 3, title: "c"), d = Item(id: 4, title: "d")
        #expect(try IdentifiedElementMerge<Item>().merge(base: [a, b, c], ours: [a, b, c, d], theirs: [c, a, b]) == [c, d, a, b], "Ours's addition follows c.")
        #expect(try IdentifiedElementMerge<Item>().merge(base: [a, b, c], ours: [b, a, c], theirs: [c, a, b]) == [b, a, c], "Both reordered, so ours leads.")
    }

    @Test func repeatedIDsConflict() {
        #expect(throws: MergeConflict()) { try IdentifiedElementMerge<Item>().merge(base: [a], ours: [a, a], theirs: [a]) }
    }

    @Test func withoutABaseAnElementOnlyOneSideHasConflicts() throws {
        #expect(try IdentifiedElementMerge<Item>().merge(ours: [a, b], theirs: [b, a]) == [a, b])
        #expect(throws: MergeConflict.self) { try IdentifiedElementMerge<Item>().merge(ours: [a, b], theirs: [a]) }
    }
}

@Suite struct DefaultMergeElementTests {
    @Test func anArrayOfIdentifiableElementsMergesByID() throws {
        let base = Board()
        var ours = base, theirs = base
        ours.items[0].done = true
        ours.items.append(Item(id: 3, title: "c"))
        theirs.items[0].title = "A"
        theirs.items.removeLast()
        let merged = try ours.merging(with: theirs, from: base)
        #expect(merged.items == [Item(id: 1, title: "A", done: true), Item(id: 3, title: "c")])
    }

    @Test func anArrayOfMergeableIdentifiableElementsUsesTheirOwnMerge() throws {
        let base = Board()
        var ours = base, theirs = base
        ours.tallies[0].count = 5
        theirs.tallies[0].count = 4
        #expect(try ours.merging(with: theirs, from: base).tallies == [Tally(id: 1, count: 6)])
    }

    @Test func aDictionaryWithAnyKeyMergesByKey() throws {
        let base = Board()
        var ours = base, theirs = base
        ours.byCode[Code(value: 1)]?.count = 5
        theirs.byCode[Code(value: 1)]?.count = 4
        theirs.byCode[Code(value: 2)] = Tally(id: 2, count: 1)
        let merged = try ours.merging(with: theirs, from: base)
        #expect(merged.byCode == [Code(value: 1): Tally(id: 1, count: 6), Code(value: 2): Tally(id: 2, count: 1)])
    }

    @Test func aDictionaryKeyRemovedWhileChangedConflicts() throws {
        let base = Board()
        var ours = base, theirs = base
        ours.byCode[Code(value: 1)] = nil
        theirs.byCode[Code(value: 1)]?.count = 9
        #expect(throws: MergeConflict.self) { try ours.merging(with: theirs, from: base) }
        #expect(try DefaultMerge<Board>(favoring: .theirs).merge(base: base, ours: ours, theirs: theirs).byCode == theirs.byCode)
    }

    @Test func aSetOfIdentifiableElementsMergesEditsByID() throws {
        let base = Board()
        var ours = base, theirs = base
        ours.tagged = [Item(id: 1, title: "a", done: true)]
        theirs.tagged = [Item(id: 1, title: "A")]
        #expect(try ours.merging(with: theirs, from: base).tagged == [Item(id: 1, title: "A", done: true)])
    }

}

private func merged<Value>(_ base: Value, _ ours: Value, _ theirs: Value, using strategy: some MergeStrategy<Value>) throws(MergeConflict) -> Value {
    try strategy.merge(base: base, ours: ours, theirs: theirs)
}
