#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing
@testable import Versioning

/// A counter attribute whose own merge adds both sides' changes.
struct ModelViews: Codable, Mergeable {
    var count = 0

    func merging(with theirs: ModelViews, from base: ModelViews) throws(MergeConflict) -> ModelViews {
        ModelViews(count: count + theirs.count - base.count)
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
@Model final class ModelTag {
    var id: UUID
    var name: String
    var color = ""

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
@Model final class ModelNote: Mergeable {
    var id: UUID
    var title = ""
    var body = ""
    var views = ModelViews()
    var labels: Set<String> = []
    var tags: [ModelTag] = []
    var pinned: ModelTag?
    var archive: [ModelTag]?

    init(id: UUID) {
        self.id = id
    }
}

/// Three versions of one note, each with its own copies of the same tags,
/// as three contexts would hold them.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
private struct Versions {
    let container: ModelContainer
    let context: ModelContext
    let ids = (note: UUID(), a: UUID(), b: UUID(), c: UUID(), d: UUID())
    var base: ModelNote!
    var ours: ModelNote!
    var theirs: ModelNote!

    init() throws {
        container = try ModelContainer(for: ModelNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        base = note()
        ours = note()
        theirs = note()
    }

    /// A note holding tags `a` and `b`.
    func note() -> ModelNote {
        let note = ModelNote(id: ids.note)
        context.insert(note)
        note.title = "Title"
        note.tags = [tag(ids.a, "a"), tag(ids.b, "b")]
        return note
    }

    func tag(_ id: UUID, _ name: String) -> ModelTag {
        let tag = ModelTag(id: id, name: name)
        context.insert(tag)
        return tag
    }

    /// The tag `note` holds with `id`, whatever order the relationship keeps.
    func tag(_ id: UUID, in note: ModelNote) -> ModelTag {
        note.tags.first { $0.id == id }!
    }

    func merge(favoring side: KeepMerge<ModelNote>? = nil) throws(MergeConflict) -> ModelNote {
        try ModelMerge(favoring: side).merge(base: base, ours: ours, theirs: theirs)
    }
}

/// Each test returns early where SwiftData is unavailable, since Swift
/// Testing rejects `@available` on a suite.
@Suite struct ModelMergeTests {
    @Test func eachSidesChangesApply() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        versions.ours.title = "Ours"
        versions.theirs.body = "Theirs"
        let merged = try versions.merge()
        #expect(merged === versions.ours, "The merge writes into ours.")
        #expect(merged.title == "Ours")
        #expect(merged.body == "Theirs")
    }

    @Test func anAttributeBothChangedConflictsAndWritesNothing() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        versions.ours.title = "Ours"
        versions.theirs.title = "Theirs"
        versions.theirs.body = "Theirs"
        #expect(throws: MergeConflict(at: [["title"]])) { try versions.merge() }
        #expect(versions.ours.title == "Ours")
        #expect(versions.ours.body == "", "On a conflict, nothing is written.")
    }

    @Test func favoringKeepsThatSideOnlyWhereItConflicts() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        versions.ours.title = "Ours"
        versions.ours.body = "Ours"
        versions.theirs.title = "Theirs"
        let merged = try versions.merge(favoring: .theirs)
        #expect(merged.title == "Theirs")
        #expect(merged.body == "Ours")
    }

    @Test func attributesMergeByTheirTypesOwnRules() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        versions.base.labels = ["x"]
        versions.ours.labels = ["x", "y"]
        versions.theirs.labels = ["z"]
        versions.ours.views.count = 2
        versions.theirs.views.count = 3
        let merged = try versions.merge()
        #expect(merged.labels == ["y", "z"], "A set merges by membership.")
        #expect(merged.views.count == 5, "A Mergeable attribute merges by its own merge.")
    }

    @Test func aToManyRelationshipMergesAsASet() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        versions.ours.tags = [versions.tag(versions.ids.b, in: versions.ours), versions.tag(versions.ids.c, "c")]
        versions.theirs.tags.append(versions.tag(versions.ids.d, "d"))
        let merged = try versions.merge()
        #expect(Set(merged.tags.map(\.id)) == [versions.ids.b, versions.ids.c, versions.ids.d])
    }

    @Test func aModelBothSidesHoldMergesWithItsOtherVersions() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        versions.tag(versions.ids.a, in: versions.ours).name = "A"
        versions.tag(versions.ids.a, in: versions.theirs).color = "red"
        let tag = try versions.merge().tags.first { $0.id == versions.ids.a }
        #expect(tag?.name == "A")
        #expect(tag?.color == "red")
    }

    @Test func aRelatedModelConflictsAtItsPath() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        versions.tag(versions.ids.b, in: versions.ours).name = "Ours"
        versions.tag(versions.ids.b, in: versions.theirs).name = "Theirs"
        let index = try #require(versions.ours.tags.firstIndex { $0.id == versions.ids.b })
        #expect(throws: MergeConflict(at: [["tags", .index(index), "name"]])) { try versions.merge() }
    }

    @Test func aToOneRelationshipBothChangedConflicts() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        var versions = try Versions()
        versions.ours.pinned = versions.tag(versions.ids.a, in: versions.ours)
        versions.theirs.pinned = versions.tag(versions.ids.b, in: versions.theirs)
        #expect(throws: MergeConflict(at: [["pinned"]])) { try versions.merge() }
        #expect(try versions.merge(favoring: .theirs).pinned?.id == versions.ids.b)

        versions = try Versions()
        versions.theirs.pinned = versions.tag(versions.ids.b, in: versions.theirs)
        #expect(try versions.merge().pinned?.id == versions.ids.b, "Only theirs changed it.")
    }

    @Test func anOptionalToManyRelationshipMergesAsASet() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        versions.ours.archive = [versions.tag(versions.ids.c, "c")]
        versions.theirs.archive = [versions.tag(versions.ids.d, "d")]
        let merged = try versions.merge()
        #expect(Set(merged.archive?.map(\.id) ?? []) == [versions.ids.c, versions.ids.d])
    }

    @Test func withoutABaseOnlyWhatBothShareMerges() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        #expect(try ModelMerge<ModelNote>().merge(ours: versions.ours, theirs: versions.theirs) === versions.ours)
        versions.theirs.title = "Theirs"
        #expect(throws: MergeConflict(at: [["title"]])) { try ModelMerge<ModelNote>().merge(ours: versions.ours, theirs: versions.theirs) }
    }

    @Test func aMergeableModelMergesAsAModel() throws {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) else { return }
        let versions = try Versions()
        versions.theirs.body = "Theirs"
        let merged = try versions.ours.merging(with: versions.theirs, from: versions.base)
        #expect(merged.body == "Theirs")
        versions.ours.title = "Ours"
        versions.theirs.title = "Theirs"
        #expect(try versions.ours.merging(with: versions.theirs, from: versions.base, using: .favoring(.theirs)).title == "Theirs")
    }
}
#endif
