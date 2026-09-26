import Foundation
import Testing
@testable import iosbk

@Suite("VoicemailExport")
struct VoicemailExportTests {
    private func backup() throws -> Backup {
        let db = try Fixture.sqliteFile(
            domain: VoicemailExport.domain,
            rel: VoicemailExport.dbPathLike
        ) { w in
            try w.exec("""
                CREATE TABLE voicemail (
                    ROWID INTEGER PRIMARY KEY, date INTEGER, sender TEXT, duration INTEGER)
                """)
            try w.exec("INSERT INTO voicemail (ROWID, date, sender, duration) VALUES (?, ?, ?, ?)",
                       bindings: [.int(1), .int(1_600_000_000), .text("+15551112222"), .int(42)])
        }
        return try Fixture.build([
            db,
            FixtureFile(domain: VoicemailExport.domain,
                        rel: "Library/Voicemail/1.amr", data: Data("AMR-AUDIO-1".utf8)),
            FixtureFile(domain: VoicemailExport.domain,
                        rel: "Library/Voicemail/2.amr", data: Data("AMR-AUDIO-2".utf8)),
        ])
    }

    @Test("copies recordings and writes an index.csv with metadata")
    func exportsAudio() throws {
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-vm-\(UUID().uuidString)")
        let result = try VoicemailExport.run(backup: try backup(), to: dest)

        #expect(result.written.count == 2)
        let index = try String(contentsOf: dest.appending(path: "index.csv"), encoding: .utf8)
        #expect(index.contains("file,timestamp,sender,duration_seconds"))
        #expect(index.contains("+15551112222"))
        #expect(index.contains("42"))

        // The recording matched to metadata is renamed with date + sender.
        let named = result.written.first { $0.contains("15551112222") }
        #expect(named != nil)
        // Both audio payloads made it out intact.
        let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        let amr = files.filter { $0.hasSuffix(".amr") }
        #expect(amr.count == 2)
    }

    @Test("exports audio with raw names when voicemail.db is absent")
    func noDatabase() throws {
        let backup = try Fixture.build([
            FixtureFile(domain: VoicemailExport.domain,
                        rel: "Library/Voicemail/7.amr", data: Data("AMR".utf8)),
        ])
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-vm-\(UUID().uuidString)")
        let result = try VoicemailExport.run(backup: backup, to: dest)
        #expect(result.written.count == 1)
    }
}
