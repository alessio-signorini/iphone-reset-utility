import Foundation
import SQLite3

/// Thin wrapper around the system SQLite3 C API.
///
/// `iosbk` never opens a backup's SQLite files in place: callers are expected
/// to copy the file to a temporary, private location first (see
/// `Backup.openSqlite`) so the original backup is never written to, locked,
/// or otherwise mutated.
final class Sqlite {
    enum SqliteError: Error, CustomStringConvertible {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case notOpenable

        var description: String {
            switch self {
            case .openFailed(let msg): return "failed to open SQLite database: \(msg)"
            case .prepareFailed(let msg): return "failed to prepare statement: \(msg)"
            case .stepFailed(let msg): return "failed to step statement: \(msg)"
            case .notOpenable: return "file is not a readable SQLite database"
            }
        }
    }

    private var db: OpaquePointer?

    /// Opens `path` read-only. Throws `SqliteError.openFailed` if the file
    /// cannot be opened as a SQLite database at all (this is how encrypted
    /// backups are detected: an encrypted `Manifest.db` is not valid SQLite).
    init(path: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        let rc = sqlite3_open_v2(path.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw SqliteError.openFailed(msg)
        }
        self.db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// A single row of query results, keyed by column name.
    struct Row {
        let values: [String: Any]

        subscript(_ column: String) -> Any? { values[column] }

        func string(_ column: String) -> String? { values[column] as? String }
        func int(_ column: String) -> Int? {
            if let v = values[column] as? Int { return v }
            if let v = values[column] as? Int64 { return Int(v) }
            return nil
        }
        func data(_ column: String) -> Data? { values[column] as? Data }
    }

    /// Runs `sql` with no bound parameters and returns every row.
    /// Column access is defensive: callers should treat missing rows/columns
    /// as "not available on this iOS version" rather than a hard failure.
    func query(_ sql: String) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SqliteError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [Row] = []
        loop: while true {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW:
                rows.append(Self.readRow(stmt))
            case SQLITE_DONE:
                break loop
            default:
                let msg = String(cString: sqlite3_errmsg(db))
                throw SqliteError.stepFailed(msg)
            }
        }
        return rows
    }

    private static func readRow(_ stmt: OpaquePointer) -> Row {
        var values: [String: Any] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            guard let namePtr = sqlite3_column_name(stmt, i) else { continue }
            let name = String(cString: namePtr)
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER:
                values[name] = Int(sqlite3_column_int64(stmt, i))
            case SQLITE_TEXT:
                if let textPtr = sqlite3_column_text(stmt, i) {
                    values[name] = String(cString: textPtr)
                }
            case SQLITE_BLOB:
                if let blobPtr = sqlite3_column_blob(stmt, i) {
                    let size = Int(sqlite3_column_bytes(stmt, i))
                    values[name] = Data(bytes: blobPtr, count: size)
                }
            case SQLITE_FLOAT:
                values[name] = sqlite3_column_double(stmt, i)
            default:
                break // SQLITE_NULL or unknown: leave key absent
            }
        }
        return Row(values: values)
    }

    /// Whether `path` looks like a valid SQLite database file (used to detect
    /// encrypted backups, whose `Manifest.db` is not valid SQLite at all).
    static func isOpenable(path: URL) -> Bool {
        (try? Sqlite(path: path).query("SELECT 1")) != nil
    }
}
