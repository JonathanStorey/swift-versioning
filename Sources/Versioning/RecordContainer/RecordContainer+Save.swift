import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension RecordContainer {
    static let createTable = """
        CREATE TABLE IF NOT EXISTS record (
            id TEXT PRIMARY KEY NOT NULL,
            zone TEXT NOT NULL,
            owner TEXT NOT NULL,
            type TEXT NOT NULL,
            metadata BLOB,
            base TEXT,
            ours TEXT,
            theirs TEXT,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            error TEXT
        )
        """

    /// Saves `record` as this device's version: `ours`, waiting to upload.
    ///
    /// The row's id comes from the value at `id`, by ``recordID(for:type:)``. A new id adds
    /// a row. An existing id replaces `ours`, clears `isDeleted` and `error`, and keeps
    /// `base`, `theirs`, `metadata` and the zone, in one statement. Asserts that a record
    /// saved to ``Zone/public`` has no `@Encrypted` values, which the public database rejects.
    ///
    /// ```swift
    /// try container.save(our: page, id: \.slug, zone: "Pages")
    /// ```
    func save<Record: Encodable, ID: Encodable>(our record: Record, id: KeyPath<Record, ID>, zone: Zone) throws {
        assert(zone != .public || !Mirror(reflecting: record).children.contains { $0.value is any EncryptedValue },
               "The public database cannot store @Encrypted values, so \(Record.self) cannot be saved to Zone.public.")
        let id = try Self.recordID(for: record[keyPath: id], type: Self.recordType(of: Record.self))
        let ours = try Self.text(JSONRepresentation(record))
        try locked {
            try run("""
                INSERT INTO record (id, zone, owner, type, ours) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET type = excluded.type, ours = excluded.ours, is_deleted = 0, error = NULL
                """, id.uuidString, zone.name, zone.owner, Self.recordType(of: Record.self), ours)
        }
    }

    /// Saves an `Identifiable` `record` as this device's version, identified by its `id`.
    func save<Record: Encodable & Identifiable>(our record: Record, zone: Zone) throws where Record.ID: Encodable {
        try save(our: record, id: \.id, zone: zone)
    }

    /// Saves the server's version of the record `id`, with its system fields as `metadata`.
    ///
    /// A new record, or one with no local changes, takes `json` as its `base`. With local
    /// changes waiting, `json` merges into `ours` first, by the registered type's own merge.
    /// See ``Row/receive(_:merging:)``. When `type` is not registered, a merge cannot run, so
    /// `json` waits in `theirs` with the reason in `error`.
    func save(their json: JSONRepresentation, id: UUID, zone: Zone, type: String, metadata: Data?) throws(DatabaseError) {
        try update(id: id, inserting: Row(id: id, zone: zone, type: type)) { row in
            row.metadata = metadata
            row.receive(json) { ours, theirs, base in
                try ours.merging(with: theirs, from: base, as: registeredType(named: type))
            }
        }
    }

    /// Deletes the record `id` on this device.
    ///
    /// A record the server has never confirmed is removed at once, since there is nothing
    /// to delete there. Any other record waits to upload its delete, and its unsent changes,
    /// any version waiting to merge, and any error are dropped. Saving the record again
    /// before the delete uploads undoes it.
    func delete(id: UUID) throws(DatabaseError) {
        try locked { () throws(DatabaseError) in
            guard var row = try row(id: id) else { return }
            guard row.metadata != nil || row.base != nil else { return try remove(id: id) }
            row.isDeleted = true
            row.ours = .none
            row.theirs = .none
            row.error = nil
            try write(row)
        }
    }

    /// Saves that the server no longer has the record `id`, because it confirmed this
    /// device's delete or another device deleted it.
    ///
    /// The row is removed, unless this device has unsent changes. Those win: the row forgets
    /// the server's version and keeps `ours`, so the next send creates the record again.
    func save(deleted id: UUID) throws(DatabaseError) {
        try locked { () throws(DatabaseError) in
            guard let row = try row(id: id) else { return }
            guard let ours = row.ours, !row.isDeleted else { return try remove(id: id) }
            try write(Row(id: id, zone: row.zone, type: row.type, ours: ours))
        }
    }

    /// Changes the row for `id` by `change`, in one locked read and write. With no row for
    /// `id`, changes `new` and adds it, or does nothing when `new` is `nil`.
    func update(id: UUID, inserting new: Row? = nil, _ change: (inout Row) -> Void) throws(DatabaseError) {
        try locked { () throws(DatabaseError) in
            guard var row = try row(id: id) ?? new else { return }
            change(&row)
            try write(row)
        }
    }

    /// The row for `id`, or `nil` when the container has none.
    func row(id: UUID) throws(DatabaseError) -> Row? {
        var row: Row?
        try run("SELECT zone, owner, type, metadata, base, ours, theirs, is_deleted, error FROM record WHERE id = ?", id.uuidString) { (statement) throws(DatabaseError) in
            row = Row(
                id: id,
                zone: Zone(statement.text(at: 0) ?? "", owner: statement.text(at: 1) ?? ""),
                type: statement.text(at: 2) ?? "",
                metadata: statement.blob(at: 3),
                base: try statement.json(at: 4),
                ours: try statement.json(at: 5),
                theirs: try statement.json(at: 6),
                isDeleted: sqlite3_column_int(statement, 7) != 0,
                error: statement.text(at: 8)
            )
        }
        return row
    }
}

private extension RecordContainer {
    /// `json` as the text the table stores.
    static func text(_ json: JSONRepresentation) throws(DatabaseError) -> String {
        do {
            return String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        } catch {
            throw DatabaseError(code: SQLITE_MISMATCH, description: "JSON could not be stored: \(error)")
        }
    }

    /// Removes the row for `id`.
    func remove(id: UUID) throws(DatabaseError) {
        try run("DELETE FROM record WHERE id = ?", id.uuidString)
    }

    /// Writes every column of `row`, replacing any row with the same id.
    func write(_ row: Row) throws(DatabaseError) {
        try run("""
            INSERT OR REPLACE INTO record (id, zone, owner, type, metadata, base, ours, theirs, is_deleted, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, row.id.uuidString, row.zone.name, row.zone.owner, row.type, row.metadata,
            try row.base.map { (json) throws(DatabaseError) in try Self.text(json) },
            try row.ours.map { (json) throws(DatabaseError) in try Self.text(json) },
            try row.theirs.map { (json) throws(DatabaseError) in try Self.text(json) },
            row.isDeleted, row.error)
    }

    /// Prepares `sql`, binds `values` in order, and steps through it, passing each result row to `body`.
    func run(_ sql: String, _ values: Any?..., each body: (OpaquePointer) throws(DatabaseError) -> Void = { _ in }) throws(DatabaseError) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(code: sqlite3_errcode(connection), connection: connection)
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT: SQLite copies the bytes before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in zip(Int32(1)..., values) {
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, transient)
            case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case let flag as Bool: sqlite3_bind_int(statement, index, flag ? 1 : 0)
            default: sqlite3_bind_null(statement, index)
            }
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(statement)
            case SQLITE_DONE: return
            case let code: throw DatabaseError(code: code, connection: connection)
            }
        }
    }
}

private extension OpaquePointer {
    func text(at column: Int32) -> String? {
        sqlite3_column_text(self, column).map { String(cString: $0) }
    }

    func blob(at column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(self, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(self, column)))
    }

    func json(at column: Int32) throws(DatabaseError) -> JSONRepresentation? {
        guard let text = text(at: column) else { return nil }
        do {
            return try JSONDecoder().decode(JSONRepresentation.self, from: Data(text.utf8))
        } catch {
            throw DatabaseError(code: SQLITE_CORRUPT, description: "Stored JSON could not be read: \(error)")
        }
    }
}
