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
        var base: JSONRepresentation? = nil
        /// This device's saved changes the server has not confirmed, or `nil` when there is nothing to upload.
        var ours: JSONRepresentation? = nil
        /// A newer server version waiting to merge into `ours`. Nothing uploads while it waits.
        var theirs: JSONRepresentation? = nil
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
