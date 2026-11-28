// Dot syntax for the package's strategies, wherever a strategy is expected,
// as `ButtonStyle` has `.bordered`:
//
//     try ours.merging(with: theirs, from: base, using: .maximum())
//     try ours.merging(with: theirs, from: base, using: .byWord(favoring: .ours))
//
// A strategy that can conflict takes `favoring:`, the side kept wherever it
// does. One that never conflicts has none.
//
// Each is a generic function rather than a property. Swift rejects
// `where Self == ComparableMaximumMerge<Value>` on a protocol extension as a
// recursive constraint, so the value type must come in as a generic
// parameter, and only a function can declare one.

extension MergeStrategy {
    /// ``KeepMerge``: the named side, `.ours` or `.theirs`.
    public static func keep<V>(_ side: KeepMerge<V>) -> Self where Self == KeepMerge<V> {
        side
    }

    /// ``ComparableMaximumMerge``: the larger value.
    public static func maximum<V: Comparable & Sendable>() -> Self where Self == ComparableMaximumMerge<V> {
        Self()
    }

    /// ``NumericSumMerge``: a counter, so both sides' changes count.
    public static func sum<V: Numeric & Sendable>(favoring side: KeepMerge<V>? = nil) -> Self where Self == NumericSumMerge<V> {
        Self(favoring: side)
    }

    /// ``BoolTrueWinsMerge``: `true` if either side is.
    public static func trueWins() -> Self where Self == BoolTrueWinsMerge {
        Self()
    }

    /// ``SetAlgebraMembershipMerge``: what each side added and removed.
    public static func byMembership<V: SetAlgebra & Sendable>(favoring side: KeepMerge<V>? = nil) -> Self where Self == SetAlgebraMembershipMerge<V> {
        Self(favoring: side)
    }

    /// ``SetAlgebraUnionMerge``: as membership, or every element without a
    /// base.
    public static func union<V: SetAlgebra & Sendable>() -> Self where Self == SetAlgebraUnionMerge<V> {
        Self()
    }

    /// ``DictionaryKeyedMerge``: a dictionary key by key, each value by its
    /// own type.
    public static func byKey<Key: Hashable & Codable, Element: Codable>(favoring side: KeepMerge<[Key: Element]>? = nil) -> Self
    where Self == DictionaryKeyedMerge<Key, Element> {
        Self(favoring: side)
    }

    /// ``RangeReplaceableCollectionElementMerge``: element by element, like
    /// lines, or text character by character.
    public static func byElement<V: RangeReplaceableCollection & Sendable>(favoring side: KeepMerge<V>? = nil) -> Self
    where V.Element: Equatable, Self == RangeReplaceableCollectionElementMerge<V> {
        Self(favoring: side)
    }

    /// ``IdentifiedElementMerge``: an array of `Identifiable` elements, each
    /// matched by `id` and merged by its own merge.
    public static func byID<E: Identifiable & Codable>(favoring side: KeepMerge<[E]>? = nil) -> Self where Self == IdentifiedElementMerge<E> {
        Self(favoring: side)
    }

    /// ``StringWordMerge``: text word by word.
    public static func byWord<V: StringProtocol & Sendable>(favoring side: KeepMerge<V>? = nil) -> Self where Self == StringWordMerge<V> {
        Self(favoring: side)
    }

    /// ``PropertyMerge``: property by property through the encoded shape,
    /// keeping the `favoring` side only at each conflicting value.
    public static func byProperty<V: Codable>(favoring side: KeepMerge<V>? = nil) -> Self where Self == PropertyMerge<V> {
        Self(favoring: side)
    }

    /// ``DefaultMerge``: property by property, each property by its
    /// type's own rules, keeping `side` at each conflicting value.
    public static func `default`<V: Codable>(favoring side: KeepMerge<V>? = nil) -> Self where Self == DefaultMerge<V> {
        Self(favoring: side)
    }

    @available(*, deprecated, renamed: "default(favoring:)")
    public static func favoring<V: Codable>(_ side: KeepMerge<V>?) -> Self where Self == DefaultMerge<V> {
        Self(favoring: side)
    }

    /// ``RawValueMerge``: the raw value, merged by `strategy`.
    public static func rawValue<V: RawRepresentable, Strategy: MergeStrategy>(_ strategy: Strategy) -> Self
    where Strategy.Value == V.RawValue, Self == RawValueMerge<V, Strategy> {
        Self(strategy)
    }
}
