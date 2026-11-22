import Foundation
import Testing
@testable import Versioning

private struct Photo: Codable, Identifiable, Mergeable {
    var id = UUID()
    @Asset var picture: Data? = nil
}

private extension RecordContainer {
    /// The files in the row's asset folder.
    func assetFiles(id: UUID) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: assetFolder(id: id), includingPropertiesForKeys: nil)) ?? []
    }

    /// The file the row's `ours` points at for `picture`.
    func ourPicture(id: UUID) throws -> URL? {
        guard case .string(let text)? = try row(id: id)?.ours?["picture"] else { return nil }
        return URL(string: text)
    }
}

@Suite struct RecordContainerAssetTests {
    @Test func savedBytesAreCopiedIntoTheContainer() throws {
        let container = RecordContainer()
        let photo = Photo(picture: Data([1, 2, 3]))
        try container.save(our: photo, zone: "Photos")
        try FileManager.default.removeItem(at: #require(photo.$picture))

        let stored = try #require(try container.ourPicture(id: photo.id))
        #expect(stored.absoluteString.hasPrefix(container.assetFolder(id: photo.id).absoluteString))
        #expect(try Data(contentsOf: stored) == Data([1, 2, 3]))
    }

    @Test func aSavedFileIsASnapshot() throws {
        let container = RecordContainer()
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: original) }
        try Data([1]).write(to: original)
        var photo = Photo()
        photo.$picture = original
        try container.save(our: photo, zone: "Photos")
        try Data([2]).write(to: original)

        #expect(try Data(contentsOf: #require(try container.ourPicture(id: photo.id))) == Data([1]))
    }

    @Test func savingAgainRemovesTheReplacedFile() throws {
        let container = RecordContainer()
        var photo = Photo(picture: Data([1]))
        try container.save(our: photo, zone: "Photos")
        photo.picture = Data([2])
        try container.save(our: photo, zone: "Photos")

        #expect(container.assetFiles(id: photo.id).count == 1)
        #expect(try Data(contentsOf: #require(try container.ourPicture(id: photo.id))) == Data([2]))
    }

    @Test func eachVersionKeepsItsOwnFileForAMerge() throws {
        let container = RecordContainer()
        var photo = Photo(picture: Data([1]))
        try container.save(our: photo, zone: "Photos")
        try container.update(id: photo.id) { row in
            row.metadata = Data([1])
            row.confirm(row.ours!)
        }
        photo.picture = Data([2])
        try container.save(our: photo, zone: "Photos")

        let row = try #require(try container.row(id: photo.id))
        #expect(row.base?["picture"] != row.ours?["picture"])
        #expect(container.assetFiles(id: photo.id).count == 2)
    }

    @Test func removingARowRemovesItsFiles() throws {
        let container = RecordContainer()
        let photo = Photo(picture: Data([1])), other = Photo(picture: Data([2]))
        try container.save(our: photo, zone: "Photos")
        try container.save(our: other, zone: "Others")

        try container.delete(our: photo)
        #expect(!FileManager.default.fileExists(atPath: container.assetFolder(id: photo.id).path))

        try container.clear(in: "Others")
        #expect(!FileManager.default.fileExists(atPath: container.assetFolder(id: other.id).path))
    }

    @Test func clearingRemovesEveryFile() throws {
        let container = RecordContainer()
        try container.save(our: Photo(picture: Data([1])), zone: "Photos")
        try container.clear()
        #expect(!FileManager.default.fileExists(atPath: container.assets.path))
    }

    @Test func anInMemoryContainerRemovesItsFilesWhenReleased() throws {
        var container: RecordContainer? = RecordContainer()
        try container?.save(our: Photo(picture: Data([1])), zone: "Photos")
        let assets = try #require(container?.assets)
        #expect(FileManager.default.fileExists(atPath: assets.path))
        container = nil
        #expect(!FileManager.default.fileExists(atPath: assets.path))
    }
}
