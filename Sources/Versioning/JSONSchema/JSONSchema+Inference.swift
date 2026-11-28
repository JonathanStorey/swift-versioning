extension JSONSchema {
    /// A schema describing every one of `values`: a key or `null` that only
    /// some values have is optional, and an integer where another value has a
    /// decimal is a number.
    init(inferredFrom values: [JSONRepresentation]) {
        self = values.lazy.map(Self.inferred(from:)).reduce(nil) { (partial: JSONSchema?, next) in
            partial?.unified(with: next) ?? next
        } ?? .null
    }
}

private extension JSONSchema {
    static func inferred(from value: JSONRepresentation) -> JSONSchema {
        switch value {
        case .null: .null
        case .bool: .boolean
        case .number(let text): text.contains { ".eE".contains($0) } ? .number : .integer()
        case .string: .string()
        case .array(let elements): .array(JSONSchema(inferredFrom: elements))
        case .object(let pairs): .object(pairs.map { (key: $0.key, value: inferred(from: $0.value)) })
        }
    }

    /// A schema describing what either schema describes. Shapes that cannot
    /// combine keep this one.
    func unified(with other: JSONSchema) -> JSONSchema {
        switch (self, other) {
        case (.null, .null):
            .null
        case (.null, let schema), (let schema, .null):
            .optional(schema.unwrapped)
        case (.optional(let wrapped), _):
            .optional(wrapped.unified(with: other).unwrapped)
        case (_, .optional(let wrapped)):
            .optional(unified(with: wrapped).unwrapped)
        case (.integer, .integer), (.boolean, .boolean):
            self
        case (.integer, .number), (.number, .integer), (.number, .number):
            .number
        case (.string, .string):
            .string()
        // An empty array infers `.null` elements, so it takes the other array's.
        case (.array(.null), .array(let element)), (.array(let element), .array(.null)):
            .array(element)
        case (.array(let mine), .array(let yours)):
            .array(mine.unified(with: yours))
        case (.object(let mine), .object(let yours)):
            .object(Self.unified(mine, yours))
        default:
            self
        }
    }

    /// Keys in both are unified, and keys in only one are optional, in
    /// `mine`'s order with new keys at the end.
    static func unified(_ mine: Properties, _ yours: Properties) -> Properties {
        var result: Properties = mine.map { property in
            let match = yours.first { $0.key == property.key }
            return (key: property.key, value: match.map { property.value.unified(with: $0.value) } ?? .optional(property.value.unwrapped))
        }
        for property in yours where !mine.contains(where: { $0.key == property.key }) {
            result.append((key: property.key, value: .optional(property.value.unwrapped)))
        }
        return result
    }
}
