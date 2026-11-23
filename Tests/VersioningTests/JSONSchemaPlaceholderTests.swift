import Foundation
import Testing
@testable import Versioning

private struct Address: Codable {
    var city: String
    var zip: Int?
    var isHome: Bool
}

private enum Mood: String, Codable, CaseIterable {
    case calm, busy
}

/// Validates its text, so it rejects a unique placeholder.
private struct Slug: Codable {
    var text: String

    init(from decoder: any Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
        guard text.isEmpty || text.first?.isLetter == true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A slug starts with a letter."))
        }
    }
}

private struct Note: Codable {
    var id: UUID
    var title: String
    var rank: Int
    var small: Int8
    var score: Double
    var created: Date
    var isPinned: Bool
    var address: Address
    var stops: [Address]
    var tags: [String]
    var mood: Mood
    var slug: Slug

    enum CodingKeys: String, CodingKey {
        case id, rank, small, score, created, isPinned, address, stops, tags, mood, slug
        case title = "heading"
    }
}

@Suite struct JSONSchemaPlaceholderTests {
    private let recorded = try! JSONSchema.placeholder(for: Note.self)

    private func path(_ value: some Encodable) throws -> JSONRepresentation.Path? {
        recorded.scalars[try JSONRepresentation(value)]
    }

    @Test func eachScalarFindsItsCodingPath() throws {
        let note = recorded.value
        #expect(try path(note.id) == ["id"])
        #expect(try path(note.title) == ["heading"], "The path follows CodingKeys.")
        #expect(try path(note.rank) == ["rank"])
        #expect(try path(note.small) == ["small"])
        #expect(try path(note.score) == ["score"])
        #expect(try path(note.created) == ["created"])
    }

    @Test func nestedValuesFindTheirFullPath() throws {
        let note = recorded.value
        #expect(try path(note.address.city) == ["address", "city"])
        #expect(try path(note.address.zip) == ["address", "zip"], "An optional is decoded, so it has a value.")
        let stop = try #require(note.stops.first), tag = try #require(note.tags.first)
        #expect(try path(stop.city) == ["stops", 0, "city"])
        #expect(try path(tag) == ["tags", 0])
        #expect(try path(stop.city)?.description == "$.stops[0].city", "The text is a JSONPath, as SQLite reads it.")
    }

    @Test func everyScalarIsDistinct() throws {
        let note = recorded.value
        let values = try [note.title, note.address.city, note.tags[0]].map { try JSONRepresentation($0) }
            + [JSONRepresentation(note.rank), JSONRepresentation(note.score), JSONRepresentation(note.created)]
        #expect(Set(values).count == values.count)
    }

    private func flag(_ isSet: (Note) -> Bool) -> JSONRepresentation.Path? {
        recorded.flags.first { isSet($0.value) }?.path
    }

    @Test func aBoolIsNotAScalarButFindsItsPathThroughItsFlag() throws {
        #expect(try path(recorded.value.isPinned) == nil)
        #expect(recorded.value.isPinned == false && recorded.value.address.isHome == false)
        #expect(flag(\.isPinned) == ["isPinned"])
        #expect(flag(\.address.isHome) == ["address", "isHome"])
        #expect(flag { $0.stops.first?.isHome == true } == ["stops", 0, "isHome"])
    }

    @Test func eachFlagSetsOnlyItsOwnBool() {
        #expect(recorded.flags.count == 3)
        for copy in recorded.flags.map(\.value) {
            let set = [copy.isPinned, copy.address.isHome, copy.stops.first?.isHome == true].filter { $0 }
            #expect(set.count == 1)
        }
    }

    @Test func aTypeThatRejectsItsPlaceholderGetsThePlainOne() throws {
        #expect(recorded.value.mood == .calm, "A raw-value enum falls back as before.")
        #expect(recorded.value.slug.text == "")
        #expect(try path(recorded.value.slug.text) == nil)
    }

    @Test func theSchemaIsUnchanged() throws {
        #expect(try JSONSchema(for: Note.self) == JSONSchema(for: Note.self))
        let plain = try JSONSchema.placeholder(for: Address.self).value
        #expect(plain.city != "", "Only placeholder(for:) uses unique values.")
    }
}
