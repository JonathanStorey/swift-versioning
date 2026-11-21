import Foundation
import Testing
@testable import Versioning

private typealias Field = RecordRepresentation.Field

private let every: [Field] = [
    .string("Hello"),
    .int64(3),
    .double(1.5),
    .timestamp(Date(timeIntervalSinceReferenceDate: 100)),
    .bytes(Data([0, 1, 2])),
    .location(Location(latitude: 1, longitude: 2, timestamp: Date(timeIntervalSinceReferenceDate: 10))),
    .reference(RecordRepresentation.Reference(recordName: "A1", action: .deleteSelf)),
    .asset(URL(fileURLWithPath: "/tmp/photo.jpg")),
    .asset(nil),
    .list([.string("a"), .string("b")]),
    .encrypted(.int64(42)),
]

@Suite struct FieldTests {
    @Test(arguments: every)
    func everyFieldReadsBackExactly(_ field: RecordRepresentation.Field) throws {
        let data = try JSONEncoder().encode(field)
        #expect(try JSONDecoder().decode(Field.self, from: data) == field)
    }

    @Test func aFieldIsTaggedWithItsType() throws {
        #expect(try JSONRepresentation(Field.string("Hello")) == ["string": "Hello"])
        #expect(try JSONRepresentation(Field.encrypted(.int64(3))) == ["encrypted": ["int64": 3]])
        #expect(try JSONRepresentation(Field.list([.double(1.5)])) == ["list": [["double": 1.5]]])
        #expect(try JSONRepresentation(Field.asset(nil)) == ["asset": nil])
    }

    @Test func aRecordsFieldsAreAnObjectKeyedByName() throws {
        let fields: [String: Field] = ["title": .string("Hello"), "count": .int64(2)]
        #expect(try JSONRepresentation(fields) == ["title": ["string": "Hello"], "count": ["int64": 2]])
        let data = try JSONEncoder().encode(fields)
        #expect(try JSONDecoder().decode([String: Field].self, from: data) == fields)
    }

    @Test(arguments: [#"{}"#, #"{"string": "a", "int64": 1}"#, #"{"text": "a"}"#, #""a""#])
    func anythingButOneTaggedValueDoesNotDecode(_ json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Field.self, from: Data(json.utf8)) }
    }
}
