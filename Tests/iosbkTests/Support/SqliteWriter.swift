import Foundation
import SQLite3

/// Tiny writable-SQLite helper used only by test fixtures to build synthetic
/// `Manifest.db` / `Accounts3.sqlite` files (with bound parameters, unlike
/// the read-only `Sqlite` wrapper shipped in the product).
final class SqliteWriter {
    enum Binding {
        case text(String)
        case int(Int)
        case blob(Data)
    }

    private var db: OpaquePointer?

    init(path: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "SqliteWriter", code: 1)
        }
        self.db = handle
    }

    func exec(_ sql: String, bindings: [Binding] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SqliteWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        defer { sqlite3_finalize(stmt) }

        for (i, binding) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch binding {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .int(let v):
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case .blob(let d):
                _ = d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(d.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SqliteWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    deinit { close() }
}
