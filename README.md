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
