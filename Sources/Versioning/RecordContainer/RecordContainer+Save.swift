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

    // Sorted keys keep a record's JSON text the same however its dictionary is ordered.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    /// Saves `record` as this device's version: `ours`, waiting to upload.
    ///
    /// A new id adds a row. An existing id replaces `ours`, clears `isDeleted` and `error`,
    /// and keeps `base`, `theirs`, `metadata`, the zone and the owner, in one statement.
    func save<Record: Codable & Identifiable>(our record: Record, zone: String, owner: String = "__defaultOwner__") throws where Record.ID == UUID {
        let schema = try RecordSchema(for: Record.self)
        let ours = try Self.encoder.encode(RecordRepresentation.Fields(JSONRepresentation(record), schema: schema))
        try locked {
            try run("""
                INSERT INTO record (id, zone, owner, type, ours) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET type = excluded.type, ours = excluded.ours, is_deleted = 0, error = NULL
                """, record.id.uuidString, zone, owner, schema.recordType, String(decoding: ours, as: UTF8.self))
        }
    }

    /// Saves the server's version of the record `id`, with its system fields as `metadata`.
    ///
    /// A new record, or one with no local changes, takes `fields` as its `base`. With local
    /// changes waiting, `fields` merges into `ours` first by `merge`, key by key unless the
    /// record's type supplies its own. See ``Row/receive(_:merging:)``.
    func save(their fields: RecordRepresentation.Fields, id: UUID, zone: String, owner: String, type: String, metadata: Data?, merging merge: RecordRepresentation.FieldsMerge = { try $0.merging(with: $1, from: $2) }) throws {
        try locked {
            var row = try row(id: id) ?? Row(id: id, zone: zone, owner: owner, type: type)
            row.metadata = metadata
            row.receive(fields, merging: merge)
            try write(row)
        }
    }

    /// The row for `id`, or `nil` when the container has none.
    func row(id: UUID) throws -> Row? {
        var row: Row?
        try run("SELECT zone, owner, type, metadata, base, ours, theirs, is_deleted, error FROM record WHERE id = ?", id.uuidString) { statement in
            row = Row(
                id: id,
                zone: statement.text(at: 0) ?? "",
                owner: statement.text(at: 1) ?? "",
                type: statement.text(at: 2) ?? "",
                metadata: statement.blob(at: 3),
                base: try statement.fields(at: 4),
                ours: try statement.fields(at: 5),
                theirs: try statement.fields(at: 6),
                isDeleted: sqlite3_column_int(statement, 7) != 0,
                error: statement.text(at: 8)
            )
        }
        return row
    }
}

private extension RecordContainer {
    /// Writes every column of `row`, replacing any row with the same id.
    func write(_ row: Row) throws {
        func text(_ fields: RecordRepresentation.Fields?) throws -> String? {
            try fields.map { String(decoding: try Self.encoder.encode($0), as: UTF8.self) }
        }
        try run("""
            INSERT OR REPLACE INTO record (id, zone, owner, type, metadata, base, ours, theirs, is_deleted, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, row.id.uuidString, row.zone, row.owner, row.type, row.metadata, try text(row.base), try text(row.ours), try text(row.theirs), row.isDeleted, row.error)
    }

    /// Prepares `sql`, binds `values` in order, and steps through it, passing each result row to `body`.
    func run(_ sql: String, _ values: Any?..., each body: (OpaquePointer) throws -> Void = { _ in }) throws {
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

    func fields(at column: Int32) throws -> RecordRepresentation.Fields? {
        try text(at: column).map { try JSONDecoder().decode(RecordRepresentation.Fields.self, from: Data($0.utf8)) }
    }
}
