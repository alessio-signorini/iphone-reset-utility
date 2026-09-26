import Foundation
import Testing
@testable import iosbk

@Suite("Export")
struct ExportTests {
    @Test("exportFiles decrypts+copies matches preserving domain/relativePath layout")
    func exportsMatchingFiles() throws {
        let backup = try Fixture.build([
            FixtureFile(domain: "HomeDomain", rel: "Library/Passes/a.pkpass", data: Data("pass-a".utf8)),
            FixtureFile(domain: "HomeDomain", rel: "Library/Passes/sub/b.pkpass", data: Data("pass-b".utf8)),
            FixtureFile(domain: "HomeDomain", rel: "Library/Other/c.txt", data: Data("nope".utf8)),
        ])
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-export-\(UUID().uuidString)")

        let n = try backup.exportFiles(domain: "HomeDomain", pathLike: "Library/Passes/%", to: dest)
        #expect(n == 2)

        let a = dest.appending(path: "HomeDomain/Library/Passes/a.pkpass")
        let b = dest.appending(path: "HomeDomain/Library/Passes/sub/b.pkpass")
        let c = dest.appending(path: "HomeDomain/Library/Other/c.txt")
        #expect(try Data(contentsOf: a) == Data("pass-a".utf8))
        #expect(try Data(contentsOf: b) == Data("pass-b".utf8))
        #expect(!FileManager.default.fileExists(atPath: c.path))
    }

    @Test("exportFiles skips path-traversal relativePaths")
    func rejectsTraversal() throws {
        let backup = try Fixture.build([
            FixtureFile(domain: "HomeDomain", rel: "../../escape.txt", data: Data("evil".utf8)),
            FixtureFile(domain: "HomeDomain", rel: "safe.txt", data: Data("ok".utf8)),
        ])
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-export-\(UUID().uuidString)")

        let n = try backup.exportFiles(domain: "HomeDomain", to: dest)
        #expect(n == 1)
        #expect(try Data(contentsOf: dest.appending(path: "HomeDomain/safe.txt")) == Data("ok".utf8))
        // The traversal entry must not have been written outside dest.
        #expect(!FileManager.default.fileExists(
            atPath: dest.deletingLastPathComponent().appending(path: "escape.txt").path))
    }

    @Test("export wallet packs each .pkpass bundle into one recognisably-named file")
    func packsWalletPasses() throws {
        let pass = try JSONSerialization.data(withJSONObject: [
            "organizationName": "Acme", "description": "Coffee Card", "serialNumber": "123",
        ])
        let backup = try Fixture.build([
            FixtureFile(domain: "HomeDomain", rel: "Library/Passes/Cards.sqlite", data: Data("db".utf8)),
            FixtureFile(domain: "HomeDomain", rel: "Library/Passes/AAA.pkpass/pass.json", data: pass),
            FixtureFile(domain: "HomeDomain", rel: "Library/Passes/AAA.pkpass/icon.png", data: Data([1, 2, 3])),
            // A bundle without pass.json is not a valid pass and must be skipped.
            FixtureFile(domain: "HomeDomain", rel: "Library/Passes/BBB.pkpass/logo.png", data: Data([9])),
        ])
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-wallet-\(UUID().uuidString)")

        let result = try WalletExport.run(backup: backup, to: dest)
        #expect(result.written == ["Acme - Coffee Card.pkpass"])
        #expect(result.skipped == 1)

        // Only the packed pass is in the output dir — no raw layout leaks out.
        let listed = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        #expect(listed == ["Acme - Coffee Card.pkpass"])

        // The written file is a valid zip whose entries sit at the archive root.
        let packed = dest.appending(path: "Acme - Coffee Card.pkpass")
        let unzipDir = dest.appending(path: "unzipped")
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", packed.path, "-d", unzipDir.path]
        try unzip.run(); unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        #expect(try Data(contentsOf: unzipDir.appending(path: "pass.json")) == pass)
        #expect(FileManager.default.fileExists(atPath: unzipDir.appending(path: "icon.png").path))
    }
}
