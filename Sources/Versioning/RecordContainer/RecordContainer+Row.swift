import Foundation

extension RecordContainer {
    /// One record in the container: its identity, and up to three versions of its fields.
    struct Row: Equatable, Sendable {
        /// The record's name in CloudKit, and the table's primary key.
        var id: UUID
        var zone: String
        /// The zone's owner: `CKCurrentUserDefaultName` in the private database, or the sharer in the shared database.
        var owner: String = "__defaultOwner__"
        /// The CloudKit record type, checked when the row is read.
        var type: String
        /// The newest system fields from the server, or `nil` before the server first confirms the record.
        var metadata: Data? = nil
        /// What the server last confirmed, or `nil` for a record never uploaded.
        var base: RecordRepresentation.Fields? = nil
        /// This device's saved changes the server has not confirmed, or `nil` when there is nothing to upload.
        var ours: RecordRepresentation.Fields? = nil
        /// A newer server version waiting to merge into `ours`. Nothing uploads while it waits.
        var theirs: RecordRepresentation.Fields? = nil
        /// A local delete the server has not confirmed.
        var isDeleted = false
        /// Why `theirs` could not merge, or, with no `theirs`, why the server rejected the upload.
        var error: String? = nil
    }
}

extension RecordContainer.Row {
    enum Status: Equatable, Sendable {
        case synced
        case waitingToUpload
        case rejected(String)
        case waitingToMerge
        case conflict(String)
    }

    /// Where the record is in syncing, worked out from the columns, never stored.
    var status: Status {
        switch (theirs, error) {
        case (.some, let error?): .conflict(error)
        case (.some, nil): .waitingToMerge
        case (nil, let error?): .rejected(error)
        case (nil, nil): ours != nil || isDeleted ? .waitingToUpload : .synced
        }
    }
}

extension RecordRepresentation {
    /// A three-way merge of a record's fields: `ours` with `theirs`, from `base`.
    typealias FieldsMerge = (_ ours: Fields, _ theirs: Fields, _ base: Fields) throws -> Fields
}

extension RecordContainer.Row {
    /// Takes `fields`, the server's newest version, as this row's `base`.
    ///
    /// With no local changes, there is nothing to merge. With local changes, `fields`
    /// merges into `ours` by `merge`, key by key unless the record's type supplies its own,
    /// and a merge that matches `fields` leaves nothing to upload. On a conflict, or a value
    /// the type cannot read, `fields` waits in `theirs`, `error` says why, and `ours` and
    /// `base` are unchanged, so nothing uploads until it is settled.
    mutating func receive(_ fields: RecordRepresentation.Fields, merging merge: RecordRepresentation.FieldsMerge = { try $0.merging(with: $1, from: $2) }) {
        guard let ours else {
            base = fields
            theirs = nil
            error = nil
            return
        }
        do {
            let merged = try merge(ours, fields, base ?? [:])
            self.ours = merged == fields ? nil : merged
            base = fields
            theirs = nil
            error = nil
        } catch let conflict as MergeConflict {
            theirs = fields
            error = "Both sides changed " + conflict.paths.map(\.description).joined(separator: ", ")
        } catch {
            theirs = fields
            self.error = String(describing: error)
        }
    }
}
