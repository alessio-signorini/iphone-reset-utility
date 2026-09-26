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
    case manifestUnreadable(String)
    case notFound(String)
    case noBackupsFound(URL)

    var description: String {
        switch self {
        case .encrypted:
            return "This backup is encrypted. iosbk v1 only supports unencrypted backups. " +
                "In Finder/Apple Configurator, uncheck \"Encrypt local backup\" and make a new backup."
        case .manifestUnreadable(let reason):
            return "Manifest.db is not a readable SQLite database (\(reason)). " +
                "The backup may be corrupt, or the encryption password changed between backups."
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
    private let decryptor: BackupDecryptor?

    /// Returns the URL of the newest backup directory under `root`.
    static func newestDir(root: URL = defaultRoot) throws -> URL {
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
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }!
    }

    /// Finds the newest backup directory under `root` and opens it.
    static func newest(root: URL = defaultRoot) throws -> Backup {
        try Backup(dir: try newestDir(root: root))
    }

    /// Whether the backup at `dir` is password-encrypted, per the
    /// authoritative `IsEncrypted` flag in `Manifest.plist`.
    static func isEncrypted(dir: URL) -> Bool {
        let path = dir.appending(path: "Manifest.plist")
        guard let data = try? Data(contentsOf: path),
              let plist = try? Plist.read(data) else { return false }
        return (plist["IsEncrypted"] as? Bool) == true
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

        // Check Manifest.plist for the authoritative IsEncrypted flag before
        // attempting to open the database, so the error is always accurate.
        if Self.isEncrypted(dir: dir) {
            throw BackupError.encrypted
        }

        // Never open the backup's own Manifest.db in place: copy to a
        // private temp file first so we never lock/write the real backup.
        let tmp = try Self.copyToTemp(manifestPath)
        let db: Sqlite
        do {
            db = try Sqlite(path: tmp)
        } catch {
            throw BackupError.manifestUnreadable(error.localizedDescription)
        }
        // Probe with a real query, since sqlite3_open_v2 succeeds lazily for
        // some non-SQLite files until the first read.
        do {
            _ = try db.query("SELECT 1 FROM Files LIMIT 1")
        } catch {
            throw BackupError.manifestUnreadable(error.localizedDescription)
        }
        self.manifest = db
        self.decryptor = nil
    }

    /// Opens and decrypts the encrypted backup at `dir` using `password`.
    /// If `Manifest.plist` does not have `IsEncrypted = true` the password is
    /// ignored and the backup is opened as a plain unencrypted backup.
    init(dir: URL, password: String) throws {
        guard Self.isEncrypted(dir: dir) else {
            // Backup has no user password — open it the normal way.
            self = try Backup(dir: dir)
            return
        }

        let manifestPlistPath = dir.appending(path: "Manifest.plist")
        guard let plistData = try? Data(contentsOf: manifestPlistPath),
              let plist = try? Plist.read(plistData) else {
            throw BackupError.notFound(manifestPlistPath.path)
        }
        guard let keybagData = plist["BackupKeyBag"] as? Data else {
            throw BackupError.manifestUnreadable("no BackupKeyBag in Manifest.plist")
        }
        guard let manifestKey = plist["ManifestKey"] as? Data else {
            throw BackupError.manifestUnreadable("no ManifestKey in Manifest.plist")
        }

        let dec = try BackupDecryptor(keybagData: keybagData, password: password)

        let manifestDBPath = dir.appending(path: "Manifest.db")
        let encryptedDB = try Data(contentsOf: manifestDBPath)
        let plainDB = try dec.decryptManifestDB(manifestKey: manifestKey, encryptedDB: encryptedDB)

        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpDB = tmpDir.appending(path: "Manifest.db")
        try plainDB.write(to: tmpDB)

        self.dir = dir
        // Open read-write: the decrypted manifest declares WAL journal mode in
        // its header but has no `-wal` sidecar, which SQLite rejects read-only.
        self.manifest = try Sqlite(path: tmpDB, readOnly: false)
        self.decryptor = dec
    }

    /// Distinct domain names in this backup's manifest containing
    /// `substring` (case-insensitive). Useful for diagnosing a plugin whose
    /// hardcoded domain constant doesn't match what a given iOS version
    /// actually uses (e.g. `ShortcutsExport`'s app-group domain), without
    /// requiring the user to inspect `Manifest.db` by hand.
    func domains(matching substring: String) throws -> [String] {
        let sql = "SELECT DISTINCT domain FROM Files WHERE domain LIKE \(Self.quote("%\(substring)%")) COLLATE NOCASE"
        let rows = try manifest.query(sql)
        return rows.compactMap { $0.string("domain") }.sorted()
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

    /// Reads the raw physical bytes for a backup file, decrypting if needed.
    func readData(_ f: BackupFile) throws -> Data {
        guard FileManager.default.fileExists(atPath: f.path.path) else {
            throw BackupError.notFound(f.rel)
        }
        let raw = try Data(contentsOf: f.path, options: [.mappedIfSafe])
        guard let dec = decryptor else { return raw }
        // Fetch the per-file MBFile blob (protection class + wrapped key) from
        // the decrypted Manifest.db so BackupDecryptor can unwrap the file key.
        let rows = try manifest.query(
            "SELECT file FROM Files WHERE fileID = \(Self.quote(f.id)) LIMIT 1")
        let fileBlob = rows.first?.data("file")
        return try dec.decryptFile(fileBlob: fileBlob, ciphertext: raw)
    }

    /// Recovers `SSID -> Wi-Fi password` from the backup keychain.
    ///
    /// Returns an empty map for unencrypted backups (whose keychain isn't
    /// decryptable) or when `keychain-backup.plist` is absent/unreadable, so
    /// callers can treat missing passwords as "not available" rather than an
    /// error.
    func keychainWifiPasswords() -> [String: String] {
        guard let dec = decryptor else { return [:] }
        guard let file = (try? files(pathLike: "%keychain-backup.plist"))?.first,
              let data = try? readData(file),
              let plist = try? Plist.read(data)
        else { return [:] }
        return Keychain.wifiPasswords(plist: plist, decryptor: dec)
    }

    /// Recovers decrypted `genp`/`inet` password items from the backup
    /// keychain, for callers that match them to accounts (mail, VPN).
    ///
    /// Returns an empty list for unencrypted backups (no decryptable keychain)
    /// or when `keychain-backup.plist` is absent/unreadable.
    func keychainSecrets() -> [Keychain.Secret] {
        guard let dec = decryptor else { return [] }
        guard let file = (try? files(pathLike: "%keychain-backup.plist"))?.first,
              let data = try? readData(file),
              let plist = try? Plist.read(data)
        else { return [] }
        return Keychain.secrets(plist: plist, decryptor: dec)
    }

    /// Recovers DER certificates from the backup keychain (`cert` items).
    ///
    /// Returns an empty list for unencrypted backups (no decryptable keychain)
    /// or when `keychain-backup.plist` is absent/unreadable.
    func keychainCertificates() -> [Keychain.Certificate] {
        guard let dec = decryptor else { return [] }
        guard let file = (try? files(pathLike: "%keychain-backup.plist"))?.first,
              let data = try? readData(file),
              let plist = try? Plist.read(data)
        else { return [] }
        return Keychain.certificates(plist: plist, decryptor: dec)
    }

    /// Decrypts and copies every backup file matching `(domain, pathLike)`
    /// into `dest`, preserving a `<domain>/<relativePath>` layout. Returns
    /// the number of files written. Directory/symlink entries are skipped.
    ///
    /// Guards against path traversal: a decoded `relativePath` that would
    /// escape `dest` is skipped rather than written.
    @discardableResult
    func exportFiles(domain: String? = nil, pathLike: String? = nil, to dest: URL) throws -> Int {
        let root = dest.standardizedFileURL
        var count = 0
        for f in try files(domain: domain, pathLike: pathLike) {
            let out = root.appending(path: f.domain).appending(path: f.rel).standardizedFileURL
            guard out.path.hasPrefix(root.path + "/") else { continue } // reject traversal
            try FileManager.default.createDirectory(
                at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try readData(f).write(to: out)
            count += 1
        }
        return count
    }

    /// Copies a backup file (expected to be a SQLite database, e.g.
    /// `Accounts3.sqlite`) to a private temp location and opens it.
    /// For encrypted backups the file is decrypted first.
    func openSqlite(_ f: BackupFile) throws -> Sqlite {
        if decryptor != nil {
            // Decrypt to a private temp file, then open. Opened read-write
            // because a decrypted DB may declare WAL mode without a `-wal`
            // sidecar, which SQLite rejects read-only.
            let data = try readData(f)
            let tmpDir = FileManager.default.temporaryDirectory
                .appending(path: "iosbk-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let dest = tmpDir.appending(path: f.path.lastPathComponent)
            try data.write(to: dest)
            return try Sqlite(path: dest, readOnly: false)
        }
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
        // Copy WAL and SHM companions so SQLite sees a consistent snapshot
        // when the source database uses WAL journaling mode.
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: source.path + suffix)
            if fm.fileExists(atPath: companion.path) {
                try fm.copyItem(at: companion, to: URL(fileURLWithPath: dest.path + suffix))
            }
        }
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
