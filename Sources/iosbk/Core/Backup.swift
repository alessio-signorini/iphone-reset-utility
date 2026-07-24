import Foundation
import CryptoKit

/// A single logical file/directory/symlink entry from a backup's
/// `Manifest.db`, resolved to its physical, sharded location on disk.
struct BackupFile: Sendable {
    let id: String
    let domain: String
    let rel: String
    let path: URL
    /// Raw `flags` column: 1 = file, 2 = directory, 4 = symlink.
    let flags: Int

    var isFile: Bool { flags == 1 }
    var isDirectory: Bool { flags == 2 }
    var isSymlink: Bool { flags == 4 }
}

enum BackupError: Error, CustomStringConvertible {
    case encrypted
    case notFound(String)
    case noBackupsFound(URL)

    var description: String {
        switch self {
        case .encrypted:
            return "This backup is encrypted. iosbk v1 only supports unencrypted backups. " +
                "In Finder/Apple Configurator, uncheck \"Encrypt local backup\" and make a new backup."
        case .notFound(let what):
            return "Not found in backup: \(what)"
        case .noBackupsFound(let root):
            return "No backups found under \(root.path)"
        }
    }
}

/// Read-only access to a single unencrypted iOS backup directory.
///
/// The backup is never mutated: `Backup` only ever opens files for reading,
/// and any SQLite database inside the backup (`Manifest.db`, or a plugin's
/// own database such as `Accounts3.sqlite`) is copied to a private temporary
/// location before being opened, so the on-disk backup is never locked or
/// written to.
struct Backup {
    static let defaultRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/MobileSync/Backup")

    let dir: URL
    private let manifest: Sqlite

    /// Finds the newest backup directory under `root` (i.e. the directory
    /// containing a `Manifest.db`, most-recently modified).
    static func newest(root: URL = defaultRoot) throws -> Backup {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            throw BackupError.noBackupsFound(root)
        }

        let candidates = entries.filter { fm.fileExists(atPath: $0.appending(path: "Manifest.db").path) }
        guard !candidates.isEmpty else {
            throw BackupError.noBackupsFound(root)
        }

        let newest = candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }!
        return try Backup(dir: newest)
    }

    /// Opens the backup at `dir`. Throws `BackupError.encrypted` if
    /// `Manifest.db` is not a readable SQLite database (the hallmark of an
    /// encrypted backup, whose manifest is itself encrypted).
    init(dir: URL) throws {
        self.dir = dir
        let manifestPath = dir.appending(path: "Manifest.db")
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            throw BackupError.notFound(manifestPath.path)
        }

        // Never open the backup's own Manifest.db in place: copy to a
        // private temp file first so we never lock/write the real backup.
        let tmp = try Self.copyToTemp(manifestPath)
        guard let db = try? Sqlite(path: tmp) else {
            throw BackupError.encrypted
        }
        // Probe with a real query, since sqlite3_open_v2 succeeds lazily for
        // some non-SQLite files until the first read.
        guard (try? db.query("SELECT 1 FROM Files LIMIT 1")) != nil else {
            throw BackupError.encrypted
        }
        self.manifest = db
    }

    /// Resolves logical entries to physical files. Filters to `flags == 1`
    /// (plain files) unless `includeDirs` is set.
    func files(domain: String? = nil, pathLike: String? = nil, includeDirs: Bool = false) throws -> [BackupFile] {
        // Sqlite wrapper has no bind-parameter support (see Sqlite.swift);
        // build the WHERE clause with escaped literals instead of
        // parameters, since all inputs here are developer-supplied plugin
        // constants ("HomeDomain", "Library/WebClips/%", ...), not untrusted
        // user input from the backup itself.
        var sql = "SELECT fileID, domain, relativePath, flags FROM Files WHERE 1=1"
        if let domain { sql += " AND domain = \(Self.quote(domain))" }
        if let pathLike { sql += " AND relativePath LIKE \(Self.quote(pathLike))" }

        let rows = try manifest.query(sql)
        return rows.compactMap { row -> BackupFile? in
            guard let id = row.string("fileID"),
                  let dom = row.string("domain"),
                  let rel = row.string("relativePath"),
                  let flags = row.int("flags")
            else { return nil }
            if !includeDirs && flags != 1 { return nil }
            return BackupFile(id: id, domain: dom, rel: rel, path: phys(id), flags: flags)
        }
    }

    /// Reads and parses a plist-format backup file (binary or XML).
    func readPlist(_ f: BackupFile) throws -> [String: Any] {
        try Plist.read(try readData(f))
    }

    /// Reads the raw physical bytes for a backup file.
    func readData(_ f: BackupFile) throws -> Data {
        guard FileManager.default.fileExists(atPath: f.path.path) else {
            throw BackupError.notFound(f.rel)
        }
        return try Data(contentsOf: f.path, options: [.mappedIfSafe])
    }

    /// Copies a backup file (expected to be a SQLite database, e.g.
    /// `Accounts3.sqlite`) to a private temp location and opens it read-only.
    func openSqlite(_ f: BackupFile) throws -> Sqlite {
        let tmp = try Self.copyToTemp(f.path)
        return try Sqlite(path: tmp)
    }

    /// `<backup>/<fileID[0..<2]>/<fileID>`
    private func phys(_ id: String) -> URL {
        let prefix = String(id.prefix(2))
        return dir.appending(path: prefix).appending(path: id)
    }

    private static func copyToTemp(_ source: URL) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

extension String {
    /// `SHA1("<domain>-<relativePath>")`, hex-encoded — the fileID scheme
    /// used by unencrypted iOS backups since iOS 10.
    static func backupFileID(domain: String, relativePath: String) -> String {
        let input = "\(domain)-\(relativePath)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
