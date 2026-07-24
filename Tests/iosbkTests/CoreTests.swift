import Foundation
import Testing
@testable import iosbk

@Suite("Backup core")
struct BackupCoreTests {
    @Test("resolves logical entries to physical files, filtering to plain files by default")
    func resolvesFiles() throws {
        let backup = try Fixture.build([
            FixtureFile(domain: "HomeDomain", rel: "a.txt", data: Data("hello".utf8)),
            FixtureFile(domain: "HomeDomain", rel: "subdir", flags: 2),
            FixtureFile(domain: "OtherDomain", rel: "b.txt", data: Data("world".utf8)),
        ])

        let homeFiles = try backup.files(domain: "HomeDomain")
        #expect(homeFiles.count == 1)
        #expect(homeFiles.first?.rel == "a.txt")

        let allWithDirs = try backup.files(domain: "HomeDomain", includeDirs: true)
        #expect(allWithDirs.count == 2)

        let everything = try backup.files()
        #expect(everything.count == 2) // 2 plain files across both domains (dir excluded)
    }

    @Test("physical path matches SHA1(domain-relativePath), sharded by first 2 hex chars")
    func physicalPathIsShardedByHashPrefix() throws {
        let backup = try Fixture.build([
            FixtureFile(domain: "HomeDomain", rel: "a.txt", data: Data("hello".utf8)),
        ])
        let files = try backup.files(domain: "HomeDomain")
        let file = try #require(files.first)

        let expectedID = String.backupFileID(domain: "HomeDomain", relativePath: "a.txt")
        #expect(file.id == expectedID)
        #expect(file.path.deletingLastPathComponent().lastPathComponent == String(expectedID.prefix(2)))
        #expect(file.path.lastPathComponent == expectedID)
        #expect(try backup.readData(file) == Data("hello".utf8))
    }

    @Test("readPlist parses binary plists")
    func readPlistParsesBinaryPlist() throws {
        let backup = try Fixture.build([
            FixtureFile(domain: "HomeDomain", rel: "Info.plist", data: try Fixture.binaryPlist(["URL": "https://example.com"])),
        ])
        let file = try #require(try backup.files(domain: "HomeDomain").first)
        let plist = try backup.readPlist(file)
        #expect(plist["URL"] as? String == "https://example.com")
    }

    @Test("openSqlite copies the file to a temp location before opening (read-only)")
    func openSqliteCopiesToTemp() throws {
        let backup = try Fixture.accountsBackup()
        let file = try #require(try backup.files(domain: "HomeDomain", pathLike: "Library/Accounts/%").first)
        let db = try backup.openSqlite(file)
        let rows = try db.query("SELECT COUNT(*) as c FROM ZACCOUNT")
        #expect(rows.first?.int("c") == 3)
    }

    @Test("encrypted (non-SQLite) Manifest.db surfaces a clear .encrypted error")
    func encryptedBackupIsDetected() throws {
        let dir = try Fixture.encryptedBackup()
        #expect(throws: BackupError.self) {
            _ = try Backup(dir: dir)
        }
        do {
            _ = try Backup(dir: dir)
            Issue.record("expected BackupError.encrypted")
        } catch let error as BackupError {
            guard case .encrypted = error else {
                Issue.record("expected .encrypted, got \(error)")
                return
            }
        }
    }

    @Test("newest(root:) picks the most-recently-modified backup directory")
    func newestPicksMostRecent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "iosbk-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["older", "newer"] {
            let dir = root.appending(path: name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let db = try SqliteWriter(path: dir.appending(path: "Manifest.db"))
            try db.exec("CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)")
            db.close()
        }
        // Ensure a distinguishable, monotonically increasing mtime.
        let olderDate = Date(timeIntervalSinceNow: -100)
        let newerDate = Date()
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: root.appending(path: "older").path)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: root.appending(path: "newer").path)

        let backup = try Backup.newest(root: root)
        #expect(backup.dir.lastPathComponent == "newer")
    }
}

@Suite("Sqlite wrapper")
struct SqliteTests {
    @Test("query returns typed rows including text, int, and blob columns")
    func queryReturnsTypedRows() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "iosbk-sqlite-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: path) }
        let writer = try SqliteWriter(path: path)
        try writer.exec("CREATE TABLE T (name TEXT, count INTEGER, payload BLOB)")
        try writer.exec("INSERT INTO T VALUES (?, ?, ?)", bindings: [.text("hi"), .int(42), .blob(Data([1, 2, 3]))])
        writer.close()

        let db = try Sqlite(path: path)
        let rows = try db.query("SELECT * FROM T")
        #expect(rows.count == 1)
        #expect(rows.first?.string("name") == "hi")
        #expect(rows.first?.int("count") == 42)
        #expect(rows.first?.data("payload") == Data([1, 2, 3]))
    }

    @Test("isOpenable is false for non-SQLite bytes")
    func isOpenableDetectsGarbage() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "iosbk-garbage-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("garbage".utf8).write(to: path)
        #expect(Sqlite.isOpenable(path: path) == false)
    }
}

@Suite("Plist helpers")
struct PlistTests {
    @Test("reads a binary plist dictionary")
    func readsBinaryDictionary() throws {
        let data = try Fixture.binaryPlist(["a": 1, "b": "two"])
        let dict = try Plist.read(data)
        #expect(dict["a"] as? Int == 1)
        #expect(dict["b"] as? String == "two")
    }

    @Test("throws on non-dictionary root when read() is used")
    func throwsOnArrayRoot() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [1, 2, 3], format: .binary, options: 0)
        #expect(throws: Plist.PlistError.self) {
            _ = try Plist.read(data)
        }
    }
}
