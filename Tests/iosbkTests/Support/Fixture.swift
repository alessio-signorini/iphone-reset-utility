import Foundation
import CryptoKit
@testable import iosbk

/// A single logical entry to seed into a synthetic backup's `Manifest.db`.
struct FixtureFile {
    let domain: String
    let rel: String
    var flags: Int = 1 // 1 = file, 2 = directory, 4 = symlink
    var data: Data = Data()
}

/// Builds temp-dir "backups" that mimic the real on-disk layout closely
/// enough for the plugins under test: a `Manifest.db` SQLite index plus
/// sharded physical files named `SHA1("<domain>-<relativePath>")`.
enum Fixture {
    /// Creates a fresh temp-dir backup containing exactly `files` and
    /// returns it opened as a `Backup`.
    static func build(_ files: [FixtureFile]) throws -> Backup {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifestPath = dir.appending(path: "Manifest.db")
        let db = try SqliteWriter(path: manifestPath)
        try db.exec("""
            CREATE TABLE Files (
                fileID TEXT PRIMARY KEY,
                domain TEXT,
                relativePath TEXT,
                flags INTEGER,
                file BLOB
            )
            """)

        for f in files {
            let id = String.backupFileID(domain: f.domain, relativePath: f.rel)
            try db.exec(
                "INSERT INTO Files (fileID, domain, relativePath, flags, file) VALUES (?, ?, ?, ?, ?)",
                bindings: [.text(id), .text(f.domain), .text(f.rel), .int(f.flags), .blob(Data())])

            if f.flags == 1 {
                let prefix = String(id.prefix(2))
                let shardDir = dir.appending(path: prefix)
                try FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
                try f.data.write(to: shardDir.appending(path: id))
            }
        }
        db.close()

        return try Backup(dir: dir)
    }

    /// A backup dir whose `Manifest.db` is garbage (not valid SQLite),
    /// simulating an encrypted backup.
    static func encryptedBackup() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write a non-SQLite Manifest.db (as iOS does for encrypted backups).
        try Data("not a sqlite database".utf8).write(to: dir.appending(path: "Manifest.db"))
        // Write Manifest.plist with IsEncrypted = true, as a real encrypted
        // backup always has, so Backup.init(dir:) throws .encrypted.
        let plist: [String: Any] = ["IsEncrypted": true]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try plistData.write(to: dir.appending(path: "Manifest.plist"))
        return dir
    }

    // MARK: - Plist / PNG helpers

    static func binaryPlist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    /// Not a real decodable PNG — just distinct placeholder bytes. Plugins
    /// under test only ever copy these bytes through as `Data`, never
    /// decode them as an image, so validity doesn't matter.
    static func onePixelPNG(tag: String = "icon") -> Data {
        Data("PNGDATA:\(tag)".utf8)
    }

    // MARK: - Convenience backups

    /// Two web clip bundles (one with an icon, one without), a directory
    /// entry, unrelated "noise" files, and two installed apps
    /// (`AppDomain-*`).
    static func webclipsBackup() throws -> Backup {
        try build([
            FixtureFile(
                domain: "HomeDomain",
                rel: "Library/WebClips",
                flags: 2), // directory entry, should be filtered out
            FixtureFile(
                domain: "HomeDomain",
                rel: "Library/WebClips/example.com.webclip/Info.plist",
                data: try binaryPlist([
                    "URL": "https://example.com",
                    "Title": "Example",
                    "FullScreen": true,
                ])),
            FixtureFile(
                domain: "HomeDomain",
                rel: "Library/WebClips/example.com.webclip/icon.png",
                data: onePixelPNG(tag: "example")),
            FixtureFile(
                domain: "HomeDomain",
                rel: "Library/WebClips/noicon.org.webclip/Info.plist",
                data: try binaryPlist([
                    "URL": "https://noicon.org",
                    "Title": "No Icon",
                    "FullScreen": false,
                ])),
            // unrelated noise: not under Library/WebClips, and a webclip
            // dir with no URL (should be skipped).
            FixtureFile(
                domain: "HomeDomain",
                rel: "Library/Preferences/com.apple.something.plist",
                data: try binaryPlist(["Unrelated": true])),
            FixtureFile(
                domain: "HomeDomain",
                rel: "Library/WebClips/nourl.net.webclip/Info.plist",
                data: try binaryPlist(["Title": "No URL"])),
            // two installed apps, plus a built-in system app that should
            // be filtered out of the curated list.
            FixtureFile(domain: "AppDomain-com.example.foo", rel: ".com.apple.mobile_container_manager.metadata.plist"),
            FixtureFile(domain: "AppDomain-com.example.bar", rel: ".com.apple.mobile_container_manager.metadata.plist"),
            FixtureFile(domain: "AppDomain-com.apple.Health", rel: ".com.apple.mobile_container_manager.metadata.plist"),
        ])
    }

    /// A wifi known-networks plist at the first candidate path, with two
    /// networks (one hidden, one with an inferred SSID key).
    static func wifiBackup() throws -> Backup {
        let candidate = WifiPlugin.candidatePaths[0]
        let plist: [String: Any] = [
            "List": [
                ["SSID_STR": "HomeNet", "EncryptionType": "WPA", "HIDDEN_NETWORK": false],
            ],
            "OfficeNet": ["EncryptionType": "WPA2", "HIDDEN_NETWORK": true],
        ]
        return try build([
            FixtureFile(domain: candidate.domain, rel: candidate.rel, data: try binaryPlist(plist)),
        ])
    }

    /// The modern (iOS 16+) `com.apple.wifi.known-networks.plist` shape: a
    /// dictionary keyed by `wifi.network.ssid.<SSID>` whose values carry the
    /// SSID as raw bytes, a `SupportedSecurityTypes` descriptor, and `Hidden`.
    static func wifiKnownNetworksBackup() throws -> Backup {
        let candidate = WifiPlugin.candidatePaths[0]
        let plist: [String: Any] = [
            "wifi.network.ssid.HomeNet": [
                "SSID": Data("HomeNet".utf8),
                "SupportedSecurityTypes": "WPA2 Personal",
                "Hidden": false,
            ],
            "wifi.network.ssid.CafeGuest": [
                "SSID": Data("CafeGuest".utf8),
                "SupportedSecurityTypes": "Open",
                "Hidden": true,
            ],
            "wifi.network.passpoint.example.com": [
                "SupportedSecurityTypes": "WPA3 Personal",
            ],
        ]
        return try build([
            FixtureFile(domain: candidate.domain, rel: candidate.rel, data: try binaryPlist(plist)),
        ])
    }
    static func emptyBackup() throws -> Backup {
        try build([
            FixtureFile(domain: "HomeDomain", rel: "Library/Preferences/unrelated.plist"),
        ])
    }

    /// `Accounts3.sqlite`, seeded with one Mail, one CalDAV, and one "other"
    /// (unclassifiable) account row, plus its `ZACCOUNTTYPE` table.
    static func accountsBackup() throws -> Backup {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-fixture-accounts-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Build the Accounts3.sqlite physical bytes out-of-band, then seed
        // it into the Manifest via `build`.
        let accountsDBPath = tmpDir.appending(path: "Accounts3.sqlite")
        let db = try SqliteWriter(path: accountsDBPath)
        try db.exec("""
            CREATE TABLE ZACCOUNTTYPE (
                Z_PK INTEGER PRIMARY KEY,
                ZACCOUNTTYPEDESCRIPTION TEXT,
                ZIDENTIFIER TEXT
            )
            """)
        try db.exec("""
            CREATE TABLE ZACCOUNT (
                Z_PK INTEGER PRIMARY KEY,
                ZACCOUNTTYPE INTEGER,
                ZACCOUNTDESCRIPTION TEXT,
                ZUSERNAME TEXT,
                ZSERVER TEXT
            )
            """)
        try db.exec(
            "INSERT INTO ZACCOUNTTYPE (Z_PK, ZACCOUNTTYPEDESCRIPTION, ZIDENTIFIER) VALUES (?, ?, ?)",
            bindings: [.int(1), .text("IMAP"), .text("com.apple.account.IMAP")])
        try db.exec(
            "INSERT INTO ZACCOUNTTYPE (Z_PK, ZACCOUNTTYPEDESCRIPTION, ZIDENTIFIER) VALUES (?, ?, ?)",
            bindings: [.int(2), .text("CalDAV"), .text("com.apple.account.CalDAV")])
        try db.exec(
            "INSERT INTO ZACCOUNTTYPE (Z_PK, ZACCOUNTTYPEDESCRIPTION, ZIDENTIFIER) VALUES (?, ?, ?)",
            bindings: [.int(3), .text("Unknown"), .text("com.example.unknown")])
        try db.exec(
            "INSERT INTO ZACCOUNT (Z_PK, ZACCOUNTTYPE, ZACCOUNTDESCRIPTION, ZUSERNAME, ZSERVER) VALUES (?, ?, ?, ?, ?)",
            bindings: [.int(1), .int(1), .text("Work Mail"), .text("user@example.com"), .text("imap.example.com")])
        try db.exec(
            "INSERT INTO ZACCOUNT (Z_PK, ZACCOUNTTYPE, ZACCOUNTDESCRIPTION, ZUSERNAME, ZSERVER) VALUES (?, ?, ?, ?, ?)",
            bindings: [.int(2), .int(2), .text("Home Calendar"), .text("cal-user"), .text("caldav.example.com")])
        try db.exec(
            "INSERT INTO ZACCOUNT (Z_PK, ZACCOUNTTYPE, ZACCOUNTDESCRIPTION, ZUSERNAME, ZSERVER) VALUES (?, ?, ?, ?, ?)",
            bindings: [.int(3), .int(3), .text("Mystery Account"), .text("mystery"), .text("mystery.example.com")])
        db.close()

        let accountsData = try Data(contentsOf: accountsDBPath)

        return try build([
            FixtureFile(
                domain: "HomeDomain",
                rel: "Library/Accounts/Accounts3.sqlite",
                data: accountsData),
        ])
    }

    /// Builds a `FixtureFile` whose bytes are a real SQLite database, seeded
    /// by `populate`. Use with `Fixture.build([...])` to place an app
    /// database (contacts, calls, calendar, …) inside a synthetic backup.
    static func sqliteFile(
        domain: String, rel: String, _ populate: (SqliteWriter) throws -> Void
    ) throws -> FixtureFile {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-fixture-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appending(path: (rel as NSString).lastPathComponent)
        let db = try SqliteWriter(path: path)
        try populate(db)
        db.close()
        return FixtureFile(domain: domain, rel: rel, data: try Data(contentsOf: path))
    }
}

