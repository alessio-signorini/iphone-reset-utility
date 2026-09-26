import Foundation

/// Exports contacts from a backup's `AddressBook.sqlitedb` into a single
/// multi-vCard `.vcf` file. One `.vcf` holding every contact imports in one
/// step on iOS: AirDrop it to the device and tap "Add All N Contacts".
///
/// // VERIFY: the `ABPerson` / `ABMultiValue` schema and the numeric
/// `property` ids (3 = phone, 4 = email) are stable on modern iOS but should
/// be confirmed against a real backup and recorded in the PR under
/// "Verified on-device".
enum ContactsExport {
    static let domain = "HomeDomain"
    static let pathLike = "Library/AddressBook/AddressBook.sqlitedb"

    /// Property ids used by `ABMultiValue` for phones and emails.
    private static let phoneProperty = 3
    private static let emailProperty = 4

    struct Contact {
        var first: String?
        var last: String?
        var middle: String?
        var prefix: String?
        var suffix: String?
        var organization: String?
        var nickname: String?
        var note: String?
        var phones: [String] = []
        var emails: [String] = []

        /// Whether the contact has any renderable content.
        var isEmpty: Bool {
            [first, last, middle, organization, nickname].allSatisfy { ($0 ?? "").isEmpty }
                && phones.isEmpty && emails.isEmpty
        }

        var displayName: String {
            let parts = [first, last].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
            return organization ?? nickname ?? "Unknown"
        }
    }

    struct Result {
        let contactCount: Int
        let outputFile: URL
    }

    /// Reads contacts from `backup` and writes them to `output` (a `.vcf`
    /// file path). Returns how many contacts were written.
    @discardableResult
    static func run(backup: Backup, to output: URL, dryRun: Bool = false) throws -> Result {
        let contacts = try read(backup: backup, dryRun: dryRun)
        let vcf = vcard(contacts)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(vcf.utf8).write(to: output)
        return Result(contactCount: contacts.count, outputFile: output)
    }

    /// Reads and assembles `Contact`s from the address-book database.
    static func read(backup: Backup, dryRun: Bool) throws -> [Contact] {
        guard let file = try backup.files(domain: domain, pathLike: pathLike).first else {
            if dryRun { logMissing("AddressBook.sqlitedb not found in \(domain)") }
            return []
        }
        let db: Sqlite
        do { db = try backup.openSqlite(file) }
        catch {
            if dryRun { logMissing("AddressBook.sqlitedb could not be opened: \(error)") }
            return []
        }

        guard let people = try? db.query(
            "SELECT ROWID, First, Last, Middle, Prefix, Suffix, Organization, Nickname, Note FROM ABPerson")
        else {
            if dryRun { logMissing("ABPerson table not present (unencrypted backups omit contact data)") }
            return []
        }

        // Pull all multi-values once and bucket them by record id, rather
        // than issuing a per-contact query.
        var phones: [Int: [String]] = [:]
        var emails: [Int: [String]] = [:]
        if let rows = try? db.query(
            "SELECT record_id, property, value FROM ABMultiValue WHERE value IS NOT NULL") {
            for row in rows {
                guard let rec = row.int("record_id"),
                      let prop = row.int("property"),
                      let value = row.string("value"), !value.isEmpty else { continue }
                switch prop {
                case phoneProperty: phones[rec, default: []].append(value)
                case emailProperty: emails[rec, default: []].append(value)
                default: break
                }
            }
        }

        var contacts: [Contact] = []
        for row in people {
            let id = row.int("ROWID") ?? -1
            var c = Contact()
            c.first = row.string("First")
            c.last = row.string("Last")
            c.middle = row.string("Middle")
            c.prefix = row.string("Prefix")
            c.suffix = row.string("Suffix")
            c.organization = row.string("Organization")
            c.nickname = row.string("Nickname")
            c.note = row.string("Note")
            c.phones = phones[id] ?? []
            c.emails = emails[id] ?? []
            if !c.isEmpty { contacts.append(c) }
        }
        return contacts
    }

    /// Renders a multi-vCard 3.0 document.
    static func vcard(_ contacts: [Contact]) -> String {
        contacts.map(vcard(for:)).joined()
    }

    private static func vcard(for c: Contact) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        let n = [c.last, c.first, c.middle, c.prefix, c.suffix]
            .map { ExportFormat.icalEscape($0 ?? "") }
            .joined(separator: ";")
        lines.append("N:\(n)")
        lines.append("FN:\(ExportFormat.icalEscape(c.displayName))")
        if let org = c.organization, !org.isEmpty {
            lines.append("ORG:\(ExportFormat.icalEscape(org))")
        }
        if let nick = c.nickname, !nick.isEmpty {
            lines.append("NICKNAME:\(ExportFormat.icalEscape(nick))")
        }
        for phone in c.phones {
            lines.append("TEL:\(ExportFormat.icalEscape(phone))")
        }
        for email in c.emails {
            lines.append("EMAIL:\(ExportFormat.icalEscape(email))")
        }
        if let note = c.note, !note.isEmpty {
            lines.append("NOTE:\(ExportFormat.icalEscape(note))")
        }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func logMissing(_ message: String) {
        FileHandle.standardError.write("contacts: \(message)\n".data(using: .utf8)!)
    }
}
