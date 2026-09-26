import Foundation
import Testing
@testable import iosbk

@Suite("ContactsExport")
struct ContactsExportTests {
    private func backup() throws -> Backup {
        let db = try Fixture.sqliteFile(
            domain: ContactsExport.domain,
            rel: ContactsExport.pathLike
        ) { w in
            try w.exec("""
                CREATE TABLE ABPerson (
                    ROWID INTEGER PRIMARY KEY, First TEXT, Last TEXT, Middle TEXT,
                    Prefix TEXT, Suffix TEXT, Organization TEXT, Nickname TEXT, Note TEXT)
                """)
            try w.exec("""
                CREATE TABLE ABMultiValue (
                    UID INTEGER PRIMARY KEY, record_id INTEGER, property INTEGER, value TEXT)
                """)
            try w.exec(
                "INSERT INTO ABPerson (ROWID, First, Last, Organization) VALUES (?, ?, ?, ?)",
                bindings: [.int(1), .text("Jane"), .text("Doe"), .text("Acme, Inc.")])
            try w.exec(
                "INSERT INTO ABPerson (ROWID, Organization) VALUES (?, ?)",
                bindings: [.int(2), .text("Org Only")])
            // A row with no usable content should be skipped.
            try w.exec("INSERT INTO ABPerson (ROWID) VALUES (?)", bindings: [.int(3)])
            try w.exec(
                "INSERT INTO ABMultiValue (record_id, property, value) VALUES (?, ?, ?)",
                bindings: [.int(1), .int(3), .text("+15551234567")])
            try w.exec(
                "INSERT INTO ABMultiValue (record_id, property, value) VALUES (?, ?, ?)",
                bindings: [.int(1), .int(4), .text("jane@example.com")])
        }
        return try Fixture.build([db])
    }

    @Test("exports one vCard per non-empty contact with phones and emails")
    func exportsVcards() throws {
        let contacts = try ContactsExport.read(backup: try backup(), dryRun: false)
        #expect(contacts.count == 2)

        let vcf = ContactsExport.vcard(contacts)
        #expect(vcf.contains("BEGIN:VCARD"))
        #expect(vcf.contains("FN:Jane Doe"))
        #expect(vcf.contains("N:Doe;Jane;;;"))
        #expect(vcf.contains("ORG:Acme\\, Inc."))
        #expect(vcf.contains("TEL:+15551234567"))
        #expect(vcf.contains("EMAIL:jane@example.com"))
        // Org-only contact falls back to the organization for FN.
        #expect(vcf.contains("FN:Org Only"))
        #expect(vcf.components(separatedBy: "BEGIN:VCARD").count - 1 == 2)
    }

    @Test("writes a .vcf file and reports the count")
    func writesFile() throws {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-contacts-\(UUID().uuidString)/contacts.vcf")
        let result = try ContactsExport.run(backup: try backup(), to: out)
        #expect(result.contactCount == 2)
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text.hasPrefix("BEGIN:VCARD"))
    }

    @Test("returns empty when AddressBook is absent")
    func emptyWhenMissing() throws {
        let contacts = try ContactsExport.read(backup: try Fixture.emptyBackup(), dryRun: false)
        #expect(contacts.isEmpty)
    }
}
