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
    // Serializes registering, a read of a row with the write that follows it, and a
    // transaction with the saves inside it, which take the lock again.
    private let lock = NSRecursiveLock()
    /// The folder holding each row's asset files: beside the database file, or, in memory,
    /// a new folder in the temporary directory, removed with the container.
    let assets: URL
    /// The registered record types, by record type name. Read and written while locked.
    var registrations: [String: RecordType] = [String(describing: Relationship.self): Relationship.self]
    /// The strategy for the values that still conflict after a record type's own merge,
    /// stored under the lock. See ``mergeStrategy``.
    private var storedMergeStrategy: DefaultMergeStrategy<JSONRepresentation> = .favoring(.ours)

    /// How the values that still conflict after a record type's own merge are settled, so a
    /// merge never stops syncing.
    ///
    /// The default, `.favoring(.ours)`, keeps this device's value at each conflicting
    /// field and merges everything else, the field-by-field "local edit wins" of Apple's
    /// CloudKit samples. `.favoring(.theirs)` keeps the server's. A strategy must favor a
    /// side, since a conflict left standing would stop the row from syncing: it asserts,
    /// and favors ours.
    ///
    /// ```swift
    /// container.mergeStrategy = .favoring(.theirs)
    /// ```
    var mergeStrategy: DefaultMergeStrategy<JSONRepresentation> {
        get { locked { storedMergeStrategy } }
        set {
            assert(newValue.favoring != nil, "A merge strategy must favor a side, so every merge settles.")
            locked { storedMergeStrategy = newValue.favoring == nil ? .favoring(.ours) : newValue }
        }
    }

    /// The rows whose unused asset files wait for the transaction around them to end, or
    /// `nil` outside a transaction. Read and written while locked.
    var assetsToSweep: Set<UUID>?

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
        assets = url.map { $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + ".assets", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // WAL lets a read run beside a write and makes each commit cheaper.
        try execute("PRAGMA journal_mode = WAL")
        try execute(Self.createTable)
    }

    deinit {
        sqlite3_close_v2(connection)
        if url == nil { try? FileManager.default.removeItem(at: assets) }
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
    func locked<T, Failure: Error>(_ body: () throws(Failure) -> T) throws(Failure) -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The result of `body`, run as one SQLite transaction: every write in it commits
    /// together, or, when it throws, none does.
    ///
    /// Asset files no longer used are removed only once it ends, so a rolled-back row
    /// still finds its files, and files copied in for rows that never landed are removed.
    func transaction<T>(_ body: () throws(DatabaseError) -> T) throws(DatabaseError) -> T {
        try locked { () throws(DatabaseError) -> T in
            assetsToSweep = []
            defer {
                let ids = assetsToSweep ?? []
                assetsToSweep = nil
                for id in ids { sweepAssets(id: id, of: try? row(id: id)) }
            }
            try execute("BEGIN IMMEDIATE")
            do throws(DatabaseError) {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Runs one or more SQL statements that return no rows.
    func execute(_ sql: String) throws(DatabaseError) {
        let code = sqlite3_exec(connection, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw DatabaseError(code: code, connection: connection) }
    }
}
