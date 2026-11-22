# swift-versioning

Swift-first JSON for `Codable` types: a value tree that matches `JSONEncoder`,
schemas that describe a type and tell you whether two versions of it can read
each other's data, and differences between two values that can be applied,
inverted and stored.

## Installation

```swift
.package(url: "https://github.com/JonathanStorey/swift-versioning", from: "0.1.0")
```

Then add the product to a target:

```swift
.product(name: "Versioning", package: "swift-versioning")
```

```swift
import Versioning
```

## JSONRepresentation

`JSONRepresentation` is a JSON value as an enum: `null`, `bool`, `number`,
`string`, `array` and `object`. Numbers keep their exact text, so a 64-bit
integer never loses precision, and objects keep their key order while
comparing equal regardless of it.

```swift
struct Settings: Codable {
    var theme: String
    var fontSize: Int
    var tags: [String]
}

let json = try JSONRepresentation(Settings(theme: "dark", fontSize: 14, tags: ["a"]))
print(json)                      // {"theme":"dark","fontSize":14,"tags":["a"]}
json["theme"]                    // Optional(.string("dark"))
json["tags"]?[0]                 // Optional(.string("a"))

let settings = try json.decode(Settings.self)
```

`init(_:)` produces the same value as a default `JSONEncoder()`, built
directly as a tree. `decode(_:)` reads it back with `JSONDecoder` after
checking that every number is valid JSON and no object repeats a key.

Values can also be written as literals:

```swift
let value: JSONRepresentation = ["name": "Ada", "scores": [1, 2.5], "nickname": nil]
```

`JSONRepresentation` is `Codable`, `Hashable` and `Sendable`. Encoding a
representation with `JSONEncoder` writes the same bytes as encoding the
original value, as long as both use `.sortedKeys`. Without it, `JSONEncoder`
does not promise a key order.

### Paths

A `JSONRepresentation.Path` locates a value inside another. It is a
collection of `.key` and `.index` segments, written as array literals and
described in JSONPath notation.

```swift
var json: JSONRepresentation = ["rooms": [["name": "A"], ["name": "B"]]]
let path: JSONRepresentation.Path = ["rooms", 1, "name"]
print(path)                      // $.rooms[1].name
json[path]                       // Optional(.string("B"))
json[path] = "C"                 // replaces the value at the path
JSONRepresentation.Path("$.rooms[0].name") // parses the description back
```

Each segment is a `CodingKey`, so a `DecodingError`'s `codingPath` converts
to a path that points at the failing value.

## JSONSchema

`JSONSchema(for:)` describes the JSON a default `JSONEncoder()` writes for a
`Decodable` type. Property names come from `CodingKeys`, optional properties
are marked optional, and `String` and `Int` raw-value enums list their cases.

```swift
let schema = try JSONSchema(for: Settings.self)
print(schema)                    // JSON Schema text
schema.json                      // a 2020-12 document with "$schema"
```

Schemas are written in [JSON Schema draft 2020-12](https://json-schema.org/draft/2020-12),
using only keywords that dialect defines, so the schema says more than the
JSON's shape:

| Swift | Schema | 2020-12 keywords |
| --- | --- | --- |
| `UUID` | `.string(format: .uuid)` | `"format": "uuid"` |
| `URL` | `.string(format: .uriReference)` | `"format": "uri-reference"` |
| `Data` | `.string(format: .base64)` | `"contentEncoding": "base64"` |
| `Int8`, `UInt16`, … | `.integer(minimum: -128, maximum: 127)` | `"minimum"`, `"maximum"` |
| `UInt`, `UInt64` | `.integer(minimum: 0)` | `"minimum": 0` |
| `Set<Element>` | `.set(element)` | `"uniqueItems": true` |
| `[String: Value]` | `.dictionary(value)` | `"additionalProperties": <value>` |

`Int`, `Int64`, `UInt` and `UInt64` have no upper bound, so a schema is the
same on every platform. Stored schemas are read back with `Codable`, with or
without `"$schema"`.

### Compatibility

The three checks follow the rules `JSONDecoder` actually applies: extra keys
are ignored, an optional property may be missing or `null`, an integer is
accepted where a number is expected, and enum cases and integer bounds must
cover what the other side can send. A `UUID` reader does not accept any
string, and a `Set` reader does not accept an array, because it would drop
repeated elements.

```swift
let saved = try JSONSchema(for: SettingsV1.self)
let current = try JSONSchema(for: SettingsV2.self)

current.isSuperset(of: saved)    // V2 can read everything V1 wrote
current.isSubset(of: saved)      // V1 can read everything V2 writes
current.isCompatible(with: saved) // both directions
```

`contains(_:)` asks the same question of a single value: whether the type
behind the schema can decode it.

```swift
current.contains(storedJSON)     // V2 can decode this stored value
```

### Identity

`id` is a stable `UUID` computed from the schema alone. It is the same on every
platform, launch and Swift version, and equal schemas share it, so it works as
a version tag for stored data. Compatibility is not transitive, so use the
checks above rather than comparing ids when versions differ.

A schema stored with `Codable` reads back to an equal schema with the same
`id`.

## JSONDifference

`difference(from:)` lists the changes that turn one value into another.
Changes are deep, so an edit inside a nested object is reported at its own
path, and numbers compare by value, so `1` and `1.0` are not a change.

```swift
let old: JSONRepresentation = ["keep": 1, "drop": "x", "change": "A"]
let new: JSONRepresentation = ["keep": 1, "change": "B", "add": true]

let difference = new.difference(from: old)
print(difference)
// - $.drop: "x"
// ~ $.change: "A" → "B"
// + $.add: true

old.applying(difference) == new             // true
new.applying(difference.inverted()) == old  // true
```

A `JSONDifference` is a collection of `Change` values, removals first, each
either `.remove` or `.insert` with a `path`, an `element` and an optional
`associatedWith` segment. A linked removal and insertion form a replacement
(`~`) when their elements differ, or a move (`>`) when they are the same.
Moves are inferred, so a reordered array or a renamed key is reported as
moves rather than as removals and insertions:

```text
> $[2] → $[0]: "z"
> $.nickname → $.alias: {"first":"Ada"}
```

`applying(_:)` returns `nil` when the difference does not fit, such as when a
removed value is not where the difference expects it.

### Differences a type can see

`difference(from:as:)` compares two values the way a `Decodable` type reads
them. Keys the type does not declare are ignored, and an optional property
that is missing or `null` counts as unchanged. This suits stored data, where
the question is what changed for the current version of the type.

```swift
let stored: JSONRepresentation = ["theme": "dark", "fontSize": 14, "tags": ["a"], "legacy": true]
let current = try JSONRepresentation(Settings(theme: "light", fontSize: 14, tags: ["a"]))

print(current.difference(from: stored))
// ~ $.theme: "dark" → "light"
// - $.legacy: true

print(try current.difference(from: stored, as: Settings.self))
// ~ $.theme: "dark" → "light"
```

Applying it to `stored` gives a value that `Settings` decodes the same as
`current`. It throws when `JSONSchema(for:)` cannot describe the type.

### Storing a difference

`JSONDifference` is `Codable`, `Hashable` and `Sendable`. It encodes as an
array of changes, and its `description` is the readable form shown above.

## Merging

A `MergeStrategy` decides how a value merges when both sides changed it, and
throws `MergeConflict` when it cannot.

```swift
struct LongerMerge: MergeStrategy {
    func merge(base: String, ours: String, theirs: String) throws(MergeConflict) -> String {
        ours.count >= theirs.count ? ours : theirs
    }
}
```

Without a base, only equal values merge, unless the strategy implements
`merge(ours:theirs:)`.

A `MergeConflict` carries `paths`, where the versions conflict, relative to
the merged value. A strategy for one value conflicts at `[]`, the whole value.
One that merges parts reports every part that conflicts, so an app can ask the
user about only those:

```swift
do {
    note = try ours.merging(with: theirs, from: base)
} catch {
    for path in error.paths {
        print(path, try JSONRepresentation(ours)[path], try JSONRepresentation(theirs)[path])
    }   // $.title "Ours" "Theirs"
}
```

A strategy decides only when both sides changed a value. Where only one side
changed it, keep that side.

| Strategy | Dot syntax | Works with | Merges | Needs a base |
| --- | --- | --- | --- | --- |
| `KeepMerge` | `.keep(.ours)`, `.keep(.theirs)` | anything | the named side | no |
| `ComparableMaximumMerge` | `.maximum()` | any `Comparable` | the larger | no |
| `NumericSumMerge` | `.sum()` | any `Numeric` | both changes added, as a counter | yes |
| `BoolTrueWinsMerge` | `.trueWins()` | `Bool` | `true` if either is | no |
| `SetAlgebraMembershipMerge` | `.byMembership()` | `Set`, any `OptionSet` | additions and removals from both | yes |
| `SetAlgebraUnionMerge` | `.union()` | `Set`, any `OptionSet` | as membership, or every element without a base | no |
| `DictionaryKeyedMerge` | `.byKey()` | any `Codable` `Dictionary` | key by key, each value by its own type | no |
| `RangeReplaceableCollectionElementMerge` | `.byElement()` | arrays, `String` | element by element, like lines | yes |
| `StringWordMerge` | `.byWord()` | `String` | word by word | yes |
| `IdentifiedElementMerge` | `.byID()` | arrays of `Identifiable & Codable` | element by `id`, each by its own merge | no |
| `PropertyMerge` | `.byProperty()` | any `Codable` | property by property, by the encoded shape | no |
| `DefaultMergeStrategy` | `.favoring(_:)` | any `Codable` | property by property, each property by its type's own rules | no |
| `RawValueMerge` | `.rawValue(_:)` | any `RawRepresentable` | its raw value, by another strategy | as that strategy |

The dot syntax works wherever a strategy is expected. Each strategy that can
conflict (`.sum()`, `.byMembership()`, `.byKey()`, `.byElement()`, `.byWord()`,
`.byID()`, `.byProperty()` and `.favoring(_:)`) holds a settable `favoring` side, kept wherever it conflicts:

```swift
try ours.merging(with: theirs, from: base, using: .byWord(favoring: .ours))

var strategy = StringWordMerge<String>()
strategy.favoring = .theirs
```

`.byProperty(favoring:)` and `.favoring(_:)` keep the side only at each
conflicting value, and every other change from both sides. `.byProperty()` reads
only the encoded shape. `DefaultMergeStrategy` also lets each property's type
decide, and is what a `Codable` `Mergeable` type uses by default.

A type that merges with another version of itself conforms to `Mergeable`. A
`Codable` type has nothing to write: it merges with `DefaultMergeStrategy`,
field by field. Wherever both sides changed a property whose type is `Mergeable`, at any
depth, that type's own merge decides, so a `Views` property in a `Note` sums.
An array or set of `Identifiable` elements merges by `id`, as `.byID()` does,
and a dictionary merges by key, whatever its key type, each value by its own
merge. Any type can name a strategy instead, and a caller can choose one for a
single merge:

```swift
struct Note: Codable, Mergeable {
    var title = ""
    var tags: Set<String> = []
}

struct Views: RawRepresentable, Codable, Mergeable {
    var rawValue: Int
    func merging(with theirs: Views, from base: Views) throws(MergeConflict) -> Views {
        try merging(with: theirs, from: base, using: .rawValue(.sum()))
    }
}

let merged = try ours.merging(with: theirs, from: base)
let favoringTheirs = try ours.merging(with: theirs, from: base, using: .favoring(.theirs))
```

### Merging JSON

`merging(_:base:under:)` merges two `JSONRepresentation` values, guided by a
`JSONSchema`. A value only one side changed keeps that side. Where both
changed it, objects and dictionaries merge key by key, sets by membership and
arrays element by element. It returns the merged value and the path of every
conflict, where the merged value holds ours.

```swift
let (merged, conflicts) = ours.merging(theirs, base: base, under: try JSONSchema(for: Note.self))
for path in conflicts {
    print(path, ours[path], theirs[path])   // $.place.city "Bergen" "Tromsø"
}
```

`PropertyMerge` does the same for a `Codable` value. It throws on a
conflict, or keeps the named side at each one:

```swift
try PropertyMerge<Note>().merge(base: base, ours: ours, theirs: theirs)
try PropertyMerge<Note>(favoring: .theirs).merge(base: base, ours: ours, theirs: theirs)
```

## CloudKit records

### References

`@Reference` holds a read-only link to another `Identifiable` model as that
model's `id`, ready for CloudKit's `CKRecord.Reference`. The generic target
is inferred from the type you pass.

```swift
struct Folder: Codable, Identifiable {
    var id: UUID
}

struct Note: Codable, Identifiable {
    var id: UUID
    @Reference(Folder.self, action: .deleteSelf) var folder: Folder.ID? = nil
}

let note = Note(id: UUID(), folder: folder.id)
note.folder                      // Optional(folder.id)
```

The property is set when the model is created or decoded, and the wrapper
stores only the id and its action. It encodes a
`RecordRepresentation.Reference`, so `JSONEncoder` writes
`{"folder":{"action":"deleteSelf","recordName":"..."},"id":"..."}`. A `nil`
reference is left out, and a missing key decodes as `nil`. The target's `id`
must be a `UUID`, and the record name is its `uuidString`, which is always a
valid CloudKit record name and reads back exactly.

The action follows `CKRecord.Reference`. With `.deleteSelf`, the record
holding the property deletes itself when the target is deleted. A decoded
reference keeps the action it was saved with. Swift does not pass the
attribute's arguments to `init(from:)`, so a reference decoded as `nil` has
the action `.none`.

### Reference lists

`@References` holds a read-only to-many relationship as the targets' ids, in
order. The initializer picks how the list is stored, and the property reads
the same either way.

```swift
struct Note: Codable, Identifiable {
    var id: UUID
    @References(Attachment.self) var attachments: [UUID] = []
    @References(to: \Tag.notes, action: .deleteSelf) var tags: [UUID] = []
}

struct Tag: Codable, Identifiable {
    var id: UUID
    @References(from: \Note.tags) var notes: [UUID] = []
}
```

A target type alone stores the list as one reference list field, like
`CKRecord`'s own, so it travels with the record and two devices settle on
one list. A key path to the target's inverse stores each reference as its
own `Relationship` record instead, so the list has no size limit and edits
from two devices merge. The inverse points back at the declaring property
and reads the same links from the other end. Its link name, `"Note.tags"`,
comes from the coding key behind the key path, so it follows `CodingKeys`.

A `Relationship` is named by the declaring side, as in `"Note.tags"`, with
the declaring record's id and then the target's. Its id is a stable hash of
those three values, so the same link always maps to the same record. It
also holds `order`, the link's position in the declaring list, and
`inverseOrder`, its position in the inverse's list, and each side sorts by
its own. A new link is unplaced, and `link[orderIn: record]` places it in
either end's list without knowing which side declared it.

Either way the wrapper encodes each id as a `RecordRepresentation.Reference`
carrying the action, which a decoded list takes from its first element.
With `.deleteSelf`, the record holding the property deletes itself when any
target is deleted. An empty list is left out, and a missing key decodes as
an empty list.

Use `@Reference` for one target and `@References` for many. Add a key path
when the list should merge across devices or outgrow a field.

### Parents

`@Reference(parent:)` points at the record that owns this one, and it is
saved as the record's `parent`. CloudKit shares a record together with
every record whose parent points at it, so sharing a folder shares its notes.

```swift
struct Note: Codable, Identifiable {
    var id: UUID
    @Reference(parent: Folder.self) var folder: Folder.ID? = nil
}
```

It takes no action, because CloudKit requires a parent reference to have the
action `.none`. Its reference encodes `"isParent": true`, so the flag
survives decoding and merging, and a record has at most one parent.

### Locations

`Location` holds every value a `CLLocation` saves to a CloudKit record:
coordinate, altitude, accuracies, course, speed and timestamp. It is a plain
`Codable` value, so optional locations and lists of locations work like any
other property, and on Apple platforms it converts to and from `CLLocation`.

```swift
struct Place: Codable {
    var home: Location?
    var route: [Location] = []
}

place.home?.latitude                    // 41.88
place.home?.clLocation                  // CLLocation
Location(clLocation)                    // back from CoreLocation
```

Unmeasured values follow CoreLocation: a negative accuracy, course or speed
means the value is invalid. CoreLocation exists only on Apple platforms, so
on Linux a `Location` has no `clLocation`.

### Timestamps

`@Timestamp` holds a read-only date that the server sets, such as when
CloudKit last modified the record.

```swift
struct Note: Codable, Hashable {
    var title: String
    @Timestamp var updatedOnServer: Date? = nil
}
```

The date is read when a model is decoded and never encoded, so it is never
sent back to the server. It takes no part in equality or hashing, so two
copies that differ only in when the server saved them are equal.

### Encrypted values

`@Encrypted` marks a property that CloudKit stores encrypted end to end. It
encodes exactly as its value does, so JSON is unchanged.

```swift
@Encrypted var body: String = ""
@Encrypted var pin: Int? = nil
```

CloudKit can encrypt strings, numbers, dates, data, locations and lists of
them, but not references or assets. Encrypted fields cannot be queried,
sorted or indexed.

### Assets

`@Asset` holds a file that CloudKit stores as a `CKAsset`. The property reads
and writes `Data`, and its projected value is the file's URL, for APIs that
work with files.

```swift
struct Note: Codable {
    @Asset var attachment: Data? = nil
}

note.attachment = bytes                 // writes a temporary file
note.$attachment = fileURL              // or points at a file you own
let pdf = PDFDocument(url: note.$attachment!)
```

Reading `attachment` maps the file into memory, so bytes load only as they
are used. The wrapper encodes the URL, not the bytes. A URL is local to one
device, and CloudKit hands back a new one each time a record is fetched.

### Transient values

`@Transient` holds a value only in memory, such as a cache or interface
state. It is never encoded, it is `nil` whenever a model is decoded, and it
takes no part in equality or hashing. Its value need not be `Codable`.

```swift
@Transient var thumbnail: Image? = nil
```

### Merging record values

The record values bring their own merge, so a `Mergeable` model merges them
by their rules with nothing to write:

- `Asset` keeps the side that changed the file. Files with the same bytes
  are the same asset, so only two different files conflict.
- `Encrypted` merges its value by the value's own merge.
- `Location` keeps the later measurement by `timestamp`.
- `@References` merges its ids element by element, keeping both sides'
  additions in place.

`Asset` and `Encrypted` are also `RawRepresentable`, so where a property
wrapper cannot go, as in a SwiftData model, a plain property holds the same
value: `var attachment: Asset` with `rawValue: URL?`, or
`var pin: Encrypted<Int>` with `rawValue: Int`.

## RecordContainer

`RecordContainer` is the database that holds records, a SQLite connection
and nothing more. Without a location it lives in memory, which suits tests
and previews. With a URL it is stored in that file.

```swift
let preview = RecordContainer()                      // in memory
let container = try RecordContainer(url: storeURL)   // a file, created if needed
```

Opening a file throws a `DatabaseError` with SQLite's result code and
message. On Linux, install SQLite's headers first
(`apt-get install libsqlite3-dev`).

## Requirements

- Swift 6.0 or later (Xcode 16+)
- macOS 10.15, iOS 13, tvOS 13, watchOS 6, visionOS 1

## Testing

Tests use [Swift Testing](https://github.com/swiftlang/swift-testing).

```sh
swift test
```

Every schema is checked for 2020-12 keywords in the tests. To check them with
an independent validator as CI does, write the fixtures and run the script:

```sh
JSON_SCHEMA_FIXTURES=/tmp/schemas swift test
pip install jsonschema
python3 Scripts/validate-json-schemas.py /tmp/schemas
```
