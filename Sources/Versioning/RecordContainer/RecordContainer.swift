import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// The database that holds records: a single SQLite connection, and nothing else.
///
/// `RecordContainer()` keeps everything in memory, so it starts empty and is gone when the
/// container is released. `RecordContainer(url:)` stores the database in a file.
public final class RecordContainer: @unchecked Sendable {
    /// The database file, or `nil` when the container is in memory.
    public let url: URL?

    // Opened with SQLITE_OPEN_FULLMUTEX, so SQLite serializes every call on it.
    let connection: OpaquePointer
    // Serializes registering, and a read of a row with the write that follows it.
    private let lock = NSLock()
    /// The registered record types, by record type name. Read and written while locked.
    var registrations: [String: Registration] = [:]

    /// An empty container held in memory.
    public convenience init() {
        do {
            try self.init(path: ":memory:", url: nil)
        } catch {
            fatalError("SQLite could not open an in-memory database: \(error)")
        }
    }

    /// A container stored in the file at `url`, created if it does not exist.
    public convenience init(url: URL) throws(DatabaseError) {
        try self.init(path: url.path, url: url)
    }

    private init(path: String, url: URL?) throws(DatabaseError) {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &connection, flags, nil)
        guard code == SQLITE_OK, let connection else {
            let error = DatabaseError(code: code, connection: connection)
            sqlite3_close_v2(connection)
            throw error
        }
        self.connection = connection
        self.url = url
        try execute(Self.createTable)
    }

    deinit {
        sqlite3_close_v2(connection)
    }
}

/// An error SQLite reported, with its result code and message.
public struct DatabaseError: Error, Equatable, CustomStringConvertible {
    /// The SQLite result code, such as `SQLITE_CANTOPEN` (14).
    public let code: Int32
    public let description: String
}

extension DatabaseError {
    init(code: Int32, connection: OpaquePointer?) {
        let message = connection.flatMap { sqlite3_errmsg($0) } ?? sqlite3_errstr(code)
        self.init(code: code, description: message.map { String(cString: $0) } ?? "SQLite error \(code)")
    }
}

extension RecordContainer {
    /// The result of `body`, with no other locked work on the container running at the same time.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Runs one or more SQL statements that return no rows.
    func execute(_ sql: String) throws(DatabaseError) {
        let code = sqlite3_exec(connection, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw DatabaseError(code: code, connection: connection) }
    }
}
