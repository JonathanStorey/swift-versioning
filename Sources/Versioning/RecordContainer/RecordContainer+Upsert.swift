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
    /// A new id adds a row. An existing id replaces `ours`, clears `isDeleted` and `error`,
    /// and keeps `base`, `theirs`, `metadata`, the zone and the owner, in one statement.
    func upsert<Record: Encodable & Identifiable>(our record: Record, zone: String, owner: String = "__defaultOwner__") throws where Record.ID == UUID {
        let ours = try JSONEncoder().encode(JSONRepresentation(record))
        try run("""
            INSERT INTO record (id, zone, owner, type, ours) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET type = excluded.type, ours = excluded.ours, is_deleted = 0, error = NULL
            """, record.id.uuidString, zone, owner, String(describing: Record.self), String(decoding: ours, as: UTF8.self))
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

    func json(at column: Int32) throws -> JSONRepresentation? {
        try text(at: column).map { try JSONDecoder().decode(JSONRepresentation.self, from: Data($0.utf8)) }
    }
}
