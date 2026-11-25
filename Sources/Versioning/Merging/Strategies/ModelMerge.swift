#if canImport(SwiftData)
import SwiftData

/// Merges a SwiftData model property by property, by the rules of
/// ``DefaultMergeStrategy``, and writes the result into ours.
///
/// - An attribute only one side changed keeps that side. One both sides
///   changed merges as a `Codable` property does in ``DefaultMergeStrategy``:
///   a ``Mergeable`` type by its own merge, an array or set of `Identifiable`
///   elements by `id`, a dictionary by key, and a struct property by
///   property.
/// - A to-many relationship is a set: it merges by membership, matching
///   models by `id`, so a model either side added is kept and one either
///   side removed is dropped.
/// - A to-one relationship only one side changed keeps that side. Both
///   changing it to different models conflicts.
/// - A related model both sides hold merges with its other versions by these
///   same rules, at any depth.
///
/// A model is a reference, so the merge writes into ours and returns it. On
/// a conflict, nothing is written. With `favoring`, each conflicting
/// property takes that side, and every other change from both sides still
/// applies.
///
/// Models match by `id`, which is `persistentModelID` unless the model
/// declares its own. A model theirs adds to a relationship joins ours as
/// ours's context holds it, so it must be saved to the same store, or
/// belong to no context.
///
/// ```swift
/// try ModelMerge<Note>(favoring: .theirs).merge(base: base, ours: mine, theirs: yours)
/// ```
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
public struct ModelMerge<Value: PersistentModel>: MergeStrategy {
    /// The side kept at each conflicting property, or `nil` to throw.
    public var favoring: KeepMerge<Value>?

    public init(favoring: KeepMerge<Value>? = nil) {
        self.favoring = favoring
    }

    public func merge(base: Value, ours: Value, theirs: Value) throws(MergeConflict) -> Value {
        try ours.merged(with: theirs, base: base, favoring: favoring?.retyped())
    }

    /// Without a base, only what both sides share merges, and any property
    /// they hold differently conflicts.
    public func merge(ours: Value, theirs: Value) throws(MergeConflict) -> Value {
        try ours.merged(with: theirs, base: nil, favoring: favoring?.retyped())
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
extension MergeStrategy {
    /// ``ModelMerge``: a SwiftData model property by property, each property
    /// by its type's own rules, keeping `side` at each conflicting property.
    public static func favoring<V: PersistentModel>(_ side: KeepMerge<V>?) -> Self where Self == ModelMerge<V> {
        Self(favoring: side)
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
extension Mergeable where Self: PersistentModel {
    /// Merges property by property into this model, as ``ModelMerge`` does.
    public func merging(with theirs: Self, from base: Self) throws(MergeConflict) -> Self {
        try merging(with: theirs, from: base, using: ModelMerge())
    }

    /// Without a base, only what both versions share merges, as
    /// ``ModelMerge`` does.
    public func merging(with theirs: Self) throws(MergeConflict) -> Self {
        try merging(with: theirs, using: ModelMerge())
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
extension Mergeable where Self: PersistentModel & Codable {
    /// A `Codable` model still merges as a model, as ``ModelMerge`` does.
    public func merging(with theirs: Self, from base: Self) throws(MergeConflict) -> Self {
        try merging(with: theirs, from: base, using: ModelMerge())
    }

    /// Without a base, only what both versions share merges, as
    /// ``ModelMerge`` does.
    public func merging(with theirs: Self) throws(MergeConflict) -> Self {
        try merging(with: theirs, using: ModelMerge())
    }
}

/// The writes a merge makes once nothing conflicts, where it conflicts, and
/// the models it has reached, so a cycle of relationships ends.
private typealias ModelMergePlan = (writes: [() -> Void], conflicts: [MergeConflict.Path], visited: Set<ObjectIdentifier>)

// MARK: - Models

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
private extension PersistentModel {
    func merged(with theirs: Self, base: Self?, favoring side: KeepMerge<Void>?) throws(MergeConflict) -> Self {
        var plan: ModelMergePlan = ([], [], [])
        self.plan(merging: theirs, base: base, at: [], favoring: side, into: &plan)
        guard plan.conflicts.isEmpty else { throw MergeConflict(at: plan.conflicts) }
        for write in plan.writes { write() }
        return self
    }

    /// Plans merging `theirs` into this model, property by property.
    func plan(merging theirs: Self, base: Self?, at path: MergeConflict.Path, favoring side: KeepMerge<Void>?, into plan: inout ModelMergePlan) {
        guard self !== theirs, plan.visited.insert(ObjectIdentifier(self)).inserted else { return }
        for property in Self.schemaMetadata {
            guard let keyPath = property.keypath as? any ModelPropertyPath<Self> else { continue }
            keyPath.plan(self, theirs, base: base, at: path + [.key(property.name)], favoring: side, into: &plan)
        }
    }

    /// Plans merging a relationship, read and written as the models it holds.
    func plan<Related: PersistentModel>(merging theirs: Self, base: Self?, toMany: Bool, read: (Self) -> [Related], write: @escaping (Self, [Related]) -> Void, at path: MergeConflict.Path, favoring side: KeepMerge<Void>?, into plan: inout ModelMergePlan) {
        let mine = read(self)
        let other = read(theirs)
        let original = base.map(read)
        for (offset, model) in mine.enumerated() {
            guard let counterpart = other.first(where: { $0.id == model.id }) else { continue }
            model.plan(merging: counterpart, base: original?.first { $0.id == model.id }, at: toMany ? path + [.index(offset)] : path, favoring: side, into: &plan)
        }
        guard let merged = mine.merged(with: other, base: original, toMany: toMany, favoring: side) else {
            plan.conflicts.append(path)
            return
        }
        guard Set(merged.map(\.id)) != Set(mine.map(\.id)) else { return }
        let models = merged.map { $0.resolved(in: modelContext) }
        plan.writes.append { write(self, models) }
    }

    /// This model as `context` holds it, so that a model from theirs can
    /// join ours's relationships.
    func resolved(in context: ModelContext?) -> Self {
        guard let context, let own = modelContext, own !== context else { return self }
        return context.model(for: persistentModelID) as? Self ?? self
    }

    /// Plans merging a non-optional to-one relationship to this type.
    static func plan<Root: PersistentModel>(_ keyPath: AnyKeyPath, _ ours: Root, _ theirs: Root, base: Root?, at path: MergeConflict.Path, favoring side: KeepMerge<Void>?, into plan: inout ModelMergePlan) {
        guard let keyPath = keyPath as? ReferenceWritableKeyPath<Root, Self> else { return }
        ours.plan(merging: theirs, base: base, toMany: false, read: { [$0[keyPath: keyPath]] }, write: { root, models in
            if let model = models.first { root[keyPath: keyPath] = model }
        }, at: path, favoring: side, into: &plan)
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
private extension Array where Element: PersistentModel {
    /// The models a relationship holds once merged, or `nil` where it
    /// conflicts. A to-many relationship merges by membership. A to-one
    /// relationship both sides changed conflicts, as does any relationship
    /// both sides hold differently without a base, unless `side` settles it.
    func merged(with other: [Element], base original: [Element]?, toMany: Bool, favoring side: KeepMerge<Void>?) -> [Element]? {
        let mine = Set(map(\.id))
        let theirs = Set(other.map(\.id))
        if mine == theirs { return self }
        if let original {
            let base = Set(original.map(\.id))
            if theirs == base { return self }
            if mine == base { return other }
            if toMany {
                let kept = Set.mergedByMembership(base: base, ours: mine, theirs: theirs)
                return filter { kept.contains($0.id) } + other.filter { kept.contains($0.id) && !mine.contains($0.id) }
            }
        }
        switch side {
        case .ours?: return self
        case .theirs?: return other
        case nil: return nil
        }
    }
}

// MARK: - Properties

/// A model's property, merged by the rules of its type.
private protocol ModelPropertyPath<Root> {
    associatedtype Root
    func plan(_ ours: Root, _ theirs: Root, base: Root?, at path: MergeConflict.Path, favoring side: KeepMerge<Void>?, into plan: inout ModelMergePlan)
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
extension ReferenceWritableKeyPath: ModelPropertyPath where Root: PersistentModel {
    fileprivate func plan(_ ours: Root, _ theirs: Root, base: Root?, at path: MergeConflict.Path, favoring side: KeepMerge<Void>?, into plan: inout ModelMergePlan) {
        if let relationship = Value.self as? any ModelRelationship.Type {
            relationship.plan(self, ours, theirs, base: base, at: path, favoring: side, into: &plan)
        } else if let relationship = Value.self as? any OptionalModelRelationship.Type {
            relationship.plan(self, ours, theirs, base: base, at: path, favoring: side, into: &plan)
        } else if let model = Value.self as? any PersistentModel.Type {
            model.plan(self, ours, theirs, base: base, at: path, favoring: side, into: &plan)
        } else if let attribute = Value.self as? any Codable.Type {
            attribute.plan(self, ours, theirs, base: base, at: path, favoring: side, into: &plan)
        }
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
private extension Encodable where Self: Decodable {
    /// Plans merging an attribute of this type, as ``DefaultMergeStrategy``
    /// merges a property of it.
    static func plan<Root: PersistentModel>(_ keyPath: AnyKeyPath, _ ours: Root, _ theirs: Root, base: Root?, at path: MergeConflict.Path, favoring side: KeepMerge<Void>?, into plan: inout ModelMergePlan) {
        guard let keyPath = keyPath as? ReferenceWritableKeyPath<Root, Self> else { return }
        let mine = ours[keyPath: keyPath]
        let other = theirs[keyPath: keyPath]
        let original = base.map { $0[keyPath: keyPath] }
        if other.encodesLike(original ?? mine) { return }
        if let original, mine.encodesLike(original) {
            plan.writes.append { ours[keyPath: keyPath] = other }
            return
        }
        // The attribute merges as the one property of a dictionary, so each
        // of DefaultMergeStrategy's rules for a property applies to it.
        let strategy = DefaultMergeStrategy<[String: Self]>(favoring: side?.retyped())
        do {
            let merged = if let original {
                try strategy.merge(base: ["": original], ours: ["": mine], theirs: ["": other])
            } else {
                try strategy.merge(ours: ["": mine], theirs: ["": other])
            }
            guard let value = merged[""], !value.encodesLike(mine) else { return }
            plan.writes.append { ours[keyPath: keyPath] = value }
        } catch let conflict as MergeConflict {
            plan.conflicts += conflict.paths.map { path + $0.dropFirst() }
        } catch {
            plan.conflicts.append(path)
        }
    }
}

// MARK: - Relationships

/// A relationship's value, read and written as the models it holds: an
/// array is to-many, and an optional model is to-one.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
private protocol ModelRelationship {
    associatedtype Related: PersistentModel
    static var isToMany: Bool { get }
    var models: [Related] { get }
    init(models: [Related])
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
extension Array: ModelRelationship where Element: PersistentModel {
    fileprivate static var isToMany: Bool { true }
    fileprivate var models: [Element] { self }
    fileprivate init(models: [Element]) { self = models }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
extension Optional: ModelRelationship where Wrapped: PersistentModel {
    fileprivate static var isToMany: Bool { false }
    fileprivate var models: [Wrapped] { map { [$0] } ?? [] }
    fileprivate init(models: [Wrapped]) { self = models.first }
}

/// An optional to-many relationship, which holds no models when `nil`.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
private protocol OptionalModelRelationship {
    static func plan<Root: PersistentModel>(_ keyPath: AnyKeyPath, _ ours: Root, _ theirs: Root, base: Root?, at path: MergeConflict.Path, favoring side: KeepMerge<Void>?, into plan: inout ModelMergePlan)
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
extension Optional: OptionalModelRelationship where Wrapped: ModelRelationship {
    fileprivate static func plan<Root: PersistentModel>(_ keyPath: AnyKeyPath, _ ours: Root, _ theirs: Root, base: Root?, at path: MergeConflict.Path, favoring side: KeepMerge<Void>?, into plan: inout ModelMergePlan) {
        guard let keyPath = keyPath as? ReferenceWritableKeyPath<Root, Self> else { return }
        ours.plan(merging: theirs, base: base, toMany: Wrapped.isToMany, read: { $0[keyPath: keyPath]?.models ?? [] }, write: { $0[keyPath: keyPath] = Wrapped(models: $1) }, at: path, favoring: side, into: &plan)
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
private extension ModelRelationship {
    /// Plans merging a relationship of this type.
    static func plan<Root: PersistentModel>(_ keyPath: AnyKeyPath, _ ours: Root, _ theirs: Root, base: Root?, at path: MergeConflict.Path, favoring side: KeepMerge<Void>?, into plan: inout ModelMergePlan) {
        guard let keyPath = keyPath as? ReferenceWritableKeyPath<Root, Self> else { return }
        ours.plan(merging: theirs, base: base, toMany: isToMany, read: { $0[keyPath: keyPath].models }, write: { $0[keyPath: keyPath] = Self(models: $1) }, at: path, favoring: side, into: &plan)
    }
}
#endif
