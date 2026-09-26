import Foundation

/// Extracts Apple Notes out of a backup's modern `NoteStore.sqlite` into one
/// readable file per note (plus an `index.csv`), rather than copying the raw
/// encrypted store.
///
/// Modern Notes stores each note's body as a gzip-compressed protobuf in
/// `ZICNOTEDATA.ZDATA`. This reader inflates it and renders it to Markdown:
/// bold/italic/underline/strikethrough/links/headings/lists/checklists come
/// from the text's `attributeRun` spans (`Core/NotesFormatting.swift`); tables
/// are reconstructed from Notes' embedded CRDT format (`Core/NotesTable.swift`,
/// best-effort/unverified — falls back to a placeholder if decoding fails).
///
/// // VERIFY: the `ZICCLOUDSYNCINGOBJECT` / `ZICNOTEDATA` schema and column
/// names (`ZTITLE1`, `ZCREATIONDATE1`, …) drift between iOS versions; column
/// access here is defensive (tries several candidates, skips what's missing)
/// and should be confirmed against a real backup and recorded in the PR under
/// "Verified on-device".
enum NotesExport {
    static let domain = "AppDomainGroup-group.com.apple.notes"
    static let storePathLike = "NoteStore.sqlite"

    struct Note {
        let pk: Int
        let identifier: String?
        let title: String?
        let created: Date?
        let modified: Date?
        let text: String
    }

    struct Result {
        let written: [String]
        let outputDir: URL
    }

    /// Reads every note from `backup` and writes one `.md` file per note into
    /// `dest` (named after its dashed title, or its identifier / row id when it
    /// has no title), plus an `index.csv`.
    @discardableResult
    static func run(backup: Backup, to dest: URL, dryRun: Bool = false) throws -> Result {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let notes = try read(backup: backup, dryRun: dryRun)
        var written: [String] = []
        var used = Set<String>()
        var index = [ExportFormat.csvRow(["file", "identifier", "title", "created", "modified"])]

        for note in notes {
            let base = fileName(for: note, used: &used)
            let outURL = dest.appending(path: "\(base).md")
            try Data(note.text.utf8).write(to: outURL)
            written.append(outURL.lastPathComponent)
            index.append(ExportFormat.csvRow([
                outURL.lastPathComponent,
                note.identifier ?? "",
                note.title ?? "",
                note.created.map(ExportFormat.iso8601) ?? "",
                note.modified.map(ExportFormat.iso8601) ?? "",
            ]))
        }

        if notes.isEmpty, dryRun {
            log("no notes found in \(domain)/NoteStore.sqlite")
        }
        try Data((index.joined(separator: "\n") + "\n").utf8)
            .write(to: dest.appending(path: "index.csv"))

        return Result(written: written, outputDir: dest)
    }

    /// Reads and decodes every note from the store. Missing tables/columns
    /// yield an empty list rather than a hard failure (older/unencrypted
    /// backups may omit note bodies).
    static func read(backup: Backup, dryRun: Bool) throws -> [Note] {
        guard let file = try backup.files(domain: domain, pathLike: storePathLike).first else {
            if dryRun { log("NoteStore.sqlite not found in \(domain)") }
            return []
        }
        let db: Sqlite
        do { db = try backup.openSqlite(file) }
        catch {
            if dryRun { log("NoteStore.sqlite could not be opened: \(error)") }
            return []
        }

        // Bucket note metadata by primary key (for titles/timestamps) and by
        // identifier (to resolve attachment/table references). `SELECT *`
        // keeps this resilient to column drift.
        var objectsByPk: [Int: Sqlite.Row] = [:]
        var objectsByIdentifier: [String: Sqlite.Row] = [:]
        if let rows = try? db.query("SELECT * FROM ZICCLOUDSYNCINGOBJECT") {
            for row in rows {
                if let pk = row.int("Z_PK") { objectsByPk[pk] = row }
                if let id = row.string("ZIDENTIFIER") { objectsByIdentifier[id] = row }
            }
        }

        guard let dataRows = try? db.query("SELECT Z_PK, ZNOTE, ZDATA FROM ZICNOTEDATA") else {
            if dryRun { log("ZICNOTEDATA table not present (nothing to extract)") }
            return []
        }

        var notes: [Note] = []
        for row in dataRows {
            guard let blob = row.data("ZDATA"), let notePk = row.int("ZNOTE"),
                  let inflated = Gzip.inflate(blob),
                  let payload = ProtoDocument.payload(inflated),
                  let fields = Protobuf.fields(payload),
                  let rawText = fields.string(2), !rawText.isEmpty
            else { continue }

            let runs = NotesFormatting.attributeRuns(fields)
            let text = NotesFormatting.render(text: rawText, runs: runs) { attachment in
                resolveAttachment(attachment, objectsByIdentifier: objectsByIdentifier)
            }

            let obj = objectsByPk[notePk]
            let title = firstLine(rawText) ?? obj.flatMap(titleColumn)
            notes.append(Note(
                pk: notePk,
                identifier: obj?.string("ZIDENTIFIER"),
                title: title,
                created: obj.flatMap {
                    cocoaDate($0, ["ZCREATIONDATE1", "ZCREATIONDATE3", "ZCREATIONDATE2", "ZCREATIONDATE"])
                },
                modified: obj.flatMap {
                    cocoaDate($0, ["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE3", "ZMODIFICATIONDATE"])
                },
                text: text))
        }
        return notes
    }

    /// Resolves an inline attachment reference to Markdown: a rendered table
    /// when the attachment's merge data decodes as one, otherwise a plain
    /// placeholder noting its type (images/drawings/scans aren't recoverable
    /// as text).
    private static func resolveAttachment(
        _ attachment: NotesFormatting.AttachmentInfo, objectsByIdentifier: [String: Sqlite.Row]
    ) -> String {
        let uti = attachment.typeUTI ?? ""
        guard let row = objectsByIdentifier[attachment.identifier] else { return "*[attachment]*" }
        guard uti.localizedCaseInsensitiveContains("table") else { return "*[attachment: \(uti.isEmpty ? "unknown" : uti)]*" }

        for column in ["ZMERGEABLEDATA1", "ZMERGEABLEDATA2", "ZMERGEABLEDATA"] {
            if let blob = row.data(column), let rows = NotesTable.decode(blob) {
                return "\n\n" + NotesTable.markdown(rows) + "\n"
            }
        }
        return "*[table: could not decode]*"
    }

    // MARK: - Helpers

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func titleColumn(_ row: Sqlite.Row) -> String? {
        for key in ["ZTITLE1", "ZTITLE2", "ZTITLE"] {
            if let v = row.string(key), !v.isEmpty { return v }
        }
        return nil
    }

    private static func cocoaDate(_ row: Sqlite.Row, _ keys: [String]) -> Date? {
        for key in keys {
            if let v = row.double(key), v > 0 { return ExportFormat.date(fromCocoa: v) }
        }
        return nil
    }

    /// Builds a unique, filesystem-safe, dashed base name for a note.
    private static func fileName(for note: Note, used: inout Set<String>) -> String {
        let base = note.title.flatMap(slug)
            ?? note.identifier.flatMap(slug)
            ?? "note-\(note.pk)"
        var candidate = base
        var n = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// Turns a title into a dashed file-name stem (`My Note` -> `My-Note`), or
    /// `nil` if nothing usable remains.
    private static func slug(_ s: String) -> String? {
        let safe = ExportFormat.safeFileName(s, fallback: "")
        let dashed = safe.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return dashed.isEmpty ? nil : dashed
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write("notes: \(message)\n".data(using: .utf8)!)
    }
}
