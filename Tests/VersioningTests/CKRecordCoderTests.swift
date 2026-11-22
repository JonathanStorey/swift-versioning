#if canImport(CloudKit)
import CloudKit
import CoreLocation
import Foundation
import Testing
@testable import Versioning

private struct Folder: Identifiable {
    var id: UUID
}

private enum Mood: String, Codable {
    case calm, busy
}

private struct Size: Codable, Equatable {
    var width: Double
    var height: Double
}

private struct Sample: Codable, Identifiable {
    var id: UUID
    var title: String
    var count: Int
    var isPinned: Bool
    var score: Double
    var created: Date
    var bytes: Data
    var link: URL
    var mood: Mood
    var words: [String]
    var tags: Set<String>
    var size: Size
    var subtitle: String?
    @Encrypted var secret: String = ""
    var home: Location
    @Asset var file: Data? = nil
    @Reference(Folder.self) var folder: UUID? = nil
    @References(Folder.self) var related: [UUID] = []
    @Timestamp var updated: Date? = nil
}

private struct Linked: Decodable {
    var folder: RecordRepresentation.Reference
}

private struct Count: Decodable {
    var count: Int
}

private struct Shapes: Codable, Equatable {
    var id: UUID
    var sizes: [Size]
    var counts: [String: Int]
    var maybe: [String?]
    var grid: [[Int]]
    @Encrypted var pin: Int? = nil
    var none: String?
}

private struct Parented: Codable {
    var id: UUID
    @Reference(parent: Folder.self) var folder: UUID? = nil
}

private struct Note: Codable, Identifiable, Mergeable {
    var id: UUID
    var title: String
}

private struct Page: Codable, Identifiable, Mergeable {
    var id: String
    var title: String
}

private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
private let folderID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!

private let zoneID = CKRecordZone.ID(zoneName: "Notes", ownerName: CKCurrentUserDefaultName)

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private func record(_ values: [String: CKRecordValue] = [:], type: String = "Sample", name: String = id.uuidString) -> CKRecord {
    let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    for (key, value) in values { record[key] = value }
    return record
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private func folderReference(_ action: CKRecord.ReferenceAction = .none) -> CKRecord.Reference {
    CKRecord.Reference(recordID: CKRecord.ID(recordName: folderID.uuidString, zoneID: zoneID), action: action)
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private func fullSample() throws -> CKRecord {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([9]).write(to: file)
    let sample = record([
        "id": id.uuidString as NSString,
        "title": "Hello" as NSString,
        "count": 3 as NSNumber,
        "isPinned": 1 as NSNumber,
        "score": 2.5 as NSNumber,
        "created": Date(timeIntervalSinceReferenceDate: 100) as NSDate,
        "bytes": Data([1, 2]) as NSData,
        "link": "https://example.com/a" as NSString,
        "mood": "busy" as NSString,
        "words": ["a", "b"] as NSArray,
        "tags": ["x"] as NSArray,
        "size": Data(#"{"width":1,"height":2}"#.utf8) as NSData,
        "home": CLLocation(latitude: 41.88, longitude: -87.63),
        "file": CKAsset(fileURL: file),
        "folder": folderReference(.deleteSelf),
        "related": [folderReference()] as NSArray,
    ])
    sample.encryptedValues["secret"] = "pin" as NSString
    return sample
}

@Suite struct CKRecordDecoderTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func decodesEachFieldType() throws {
        let sample = try fullSample()
        let decoded = try CKRecordDecoder().decode(Sample.self, from: sample)
        let home = try #require(sample.object(forKey: "home") as? CLLocation)

        #expect(decoded.id == id)
        #expect(decoded.title == "Hello")
        #expect(decoded.count == 3)
        #expect(decoded.isPinned)
        #expect(decoded.score == 2.5)
        #expect(decoded.created == Date(timeIntervalSinceReferenceDate: 100))
        #expect(decoded.bytes == Data([1, 2]))
        #expect(decoded.link == URL(string: "https://example.com/a"))
        #expect(decoded.mood == .busy)
        #expect(decoded.words == ["a", "b"])
        #expect(decoded.tags == ["x"])
        #expect(decoded.size == Size(width: 1, height: 2))
        #expect(decoded.subtitle == nil)
        #expect(decoded.secret == "pin")
        #expect(decoded.home == Location(home))
        #expect(decoded.$file == (sample.object(forKey: "file") as? CKAsset)?.fileURL)
        #expect(decoded.file == Data([9]))
        #expect(decoded.folder == folderID)
        #expect(decoded.related == [folderID])
        #expect(decoded.updated == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func readsTheActionAndMarksTheParent() throws {
        let linked = record(["folder": folderReference(.deleteSelf)])
        let plain = try CKRecordDecoder().decode(Linked.self, from: linked).folder
        #expect(!plain.isParent)
        #expect(plain.action == .deleteSelf)
        linked["folder"] = folderReference()
        linked.parent = folderReference()
        #expect(try CKRecordDecoder().decode(Linked.self, from: linked).folder.isParent)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func throwsForAMissingField() {
        #expect(throws: DecodingError.self) { try CKRecordDecoder().decode(Count.self, from: record()) }
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func throwsForAValueOfAnotherType() {
        for value in ["three" as NSString, 1.5 as NSNumber] as [CKRecordValue] {
            #expect(throws: DecodingError.self) { try CKRecordDecoder().decode(Count.self, from: record(["count": value])) }
        }
    }
}

/// The JSON bytes the encoder stores for a nested value. Encoding these cannot fail.
private func json(_ value: some Encodable) -> Data {
    Data(try! JSONRepresentation(value).description.utf8)
}

@Suite struct CKRecordEncoderTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func roundTripsEachFieldTypeAndClearsTheRest() throws {
        let sample = try CKRecordDecoder().decode(Sample.self, from: fullSample())
        let encoded = record(["stale": "x" as NSString])
        encoded.encryptedValues["oldSecret"] = "y" as NSString

        try CKRecordEncoder().encode(sample, to: encoded)
        let decoded = try CKRecordDecoder().decode(Sample.self, from: encoded)

        #expect(try JSONRepresentation(decoded) == JSONRepresentation(sample))
        #expect(encoded.encryptedValues.allKeys() == ["secret"])
        #expect(!encoded.allKeys().contains("stale"))
        #expect(encoded.object(forKey: "id") as? String == id.uuidString)
        #expect(!encoded.allKeys().contains("subtitle"))
        #expect(!encoded.allKeys().contains("updated"))
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func storesNestedValuesAsJSON() throws {
        let shapes = Shapes(id: id, sizes: [Size(width: 1, height: 2)], counts: ["a": 1], maybe: ["b", nil], grid: [[1], [2, 3]], pin: 4)
        let encoded = record(type: "Shapes")
        try CKRecordEncoder().encode(shapes, to: encoded)

        #expect(encoded.object(forKey: "sizes") as? [Data] == [json(shapes.sizes[0])])
        #expect(encoded.object(forKey: "counts") as? Data == json(shapes.counts))
        #expect(encoded.object(forKey: "maybe") as? Data == json(shapes.maybe))
        #expect(encoded.object(forKey: "grid") as? Data == json(shapes.grid))
        #expect(encoded.encryptedValues["pin"] as? Int64 == 4)
        #expect(encoded.object(forKey: "pin") == nil)
        #expect(try CKRecordDecoder().decode(Shapes.self, from: encoded) == shapes)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func setsAndClearsTheParent() throws {
        let source = record(["id": id.uuidString as NSString, "folder": folderReference()])
        source.parent = folderReference()
        let parented = try CKRecordDecoder().decode(Parented.self, from: source)

        let encoded = record()
        try CKRecordEncoder().encode(parented, to: encoded)
        #expect(encoded.parent?.recordID == folderReference().recordID)
        #expect((encoded.object(forKey: "folder") as? CKRecord.Reference)?.recordID == folderReference().recordID)

        try CKRecordEncoder().encode(Parented(id: id), to: encoded)
        #expect(encoded.parent == nil)
        #expect(encoded.object(forKey: "folder") == nil)
    }
}

@Suite struct RecordContainerCloudKitTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func savesARecordNamedByAHashOfItsID() throws {
        let page = Page(id: "intro", title: "Hello")
        let name = try RecordContainer.recordID(of: page)
        let container = RecordContainer()
        container.register(Page.self)
        try container.save(their: record(["id": "intro" as NSString, "title": "Hello" as NSString], type: "Page", name: name.uuidString))

        let row = try #require(try container.row(id: name))
        #expect(row.base == (try? JSONRepresentation(page)))
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func savesTheDecodedRecordAsBase() throws {
        let container = RecordContainer()
        container.register(Note.self)
        try container.save(their: record(["id": id.uuidString as NSString, "title": "Hello" as NSString], type: "Note"))

        let row = try #require(try container.row(id: id))
        #expect(row.base == (try? JSONRepresentation(Note(id: id, title: "Hello"))))
        #expect(row.zone == "Notes")
        #expect(row.owner == CKCurrentUserDefaultName)
        #expect(row.type == "Note")
        #expect(row.metadata != nil)
        #expect(row.status == .synced, "\(row)")
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func throwsWithoutSaving() throws {
        let container = RecordContainer()
        container.register(Note.self)
        let unnamed = record(["title": "Hello" as NSString], type: "Note", name: "not-a-uuid")
        #expect(throws: DecodingError.self) { try container.save(their: unnamed) }
        #expect(throws: DecodingError.self) { try container.save(their: record(type: "Other")) }
        #expect(throws: DecodingError.self) { try container.save(their: record(type: "Note")) }
        #expect(try container.row(id: id) == nil)
    }
}
#endif
