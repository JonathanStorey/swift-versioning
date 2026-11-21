import Foundation
import Testing
@testable import Versioning

private struct Photo: Codable, Identifiable {
    var id: UUID
}

private struct Nested: Codable, Equatable {
    var note = "Inside"
}

private let photo = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let moment = Date(timeIntervalSinceReferenceDate: 100)

private struct Card: Codable, Equatable {
    var title = "Hello"
    var count = 3
    var isDone = true
    var score = 1.5
    var due = moment
    var attachment = Data([1, 2])
    var place: Location? = Location(latitude: 1, longitude: 2, timestamp: moment)
    var tags = ["a", "b"]
    var nested = Nested()
    @Encrypted var pin = 42
    @References(Photo.self) var photos: [UUID] = [photo]
}

@Suite struct FieldJSONTests {
    private let schema = try! RecordSchema(for: Card.self)

    @Test func eachPropertyIsStoredAsItsCloudKitType() throws {
        let fields = try RecordRepresentation.Fields(JSONRepresentation(Card()), schema: schema)
        #expect(fields["title"] == .string("Hello"))
        #expect(fields["count"] == .int64(3))
        #expect(fields["isDone"] == .int64(1))
        #expect(fields["score"] == .double(1.5))
        #expect(fields["due"] == .timestamp(moment))
        #expect(fields["attachment"] == .bytes(Data([1, 2])))
        #expect(fields["place"] == .location(Location(latitude: 1, longitude: 2, timestamp: moment)))
        #expect(fields["tags"] == .list([.string("a"), .string("b")]))
        #expect(fields["pin"] == .encrypted(.int64(42)))
        #expect(fields["photos"] == .list([.reference(.init(recordName: photo.uuidString))]))
        #expect(fields["nested"] == .bytes(Data(#"{"note":"Inside"}"#.utf8)))
    }

    @Test func fieldsReadBackAsTheSameValue() throws {
        let card = Card()
        let fields = try RecordRepresentation.Fields(JSONRepresentation(card), schema: schema)
        #expect(try JSONRepresentation(fields, schema: schema).decode(Card.self) == card)
    }

    @Test func aMissingOptionalStoresNoField() throws {
        var card = Card()
        card.place = nil
        let fields = try RecordRepresentation.Fields(JSONRepresentation(card), schema: schema)
        #expect(fields["place"] == nil)
        #expect(try JSONRepresentation(fields, schema: schema).decode(Card.self) == card)
    }

    @Test func undeclaredFieldsAreLeftOutOfTheJSON() throws {
        var fields = try RecordRepresentation.Fields(JSONRepresentation(Card()), schema: schema)
        fields["addedLater"] = .string("New")
        #expect(try JSONRepresentation(fields, schema: schema)["addedLater"] == nil)
    }

    @Test func aFieldOfTheWrongTypeThrows() {
        #expect(throws: DecodingError.self) {
            try JSONRepresentation(["title": .int64(3)], schema: schema)
        }
    }
}
