import Foundation

/// Exports voicemail audio out of a backup: copies each `.amr` recording into
/// an output folder (named by date + sender) and writes an `index.csv`
/// mapping each file to its metadata.
///
/// // VERIFY: the `voicemail` table schema (`ROWID`, `date`, `sender`,
/// `duration`) and the `<ROWID>.amr` file-naming convention should be
/// confirmed against a real backup and recorded in the PR under
/// "Verified on-device".
enum VoicemailExport {
    static let domain = "HomeDomain"
    static let audioPathLike = "Library/Voicemail/%.amr"
    static let dbPathLike = "Library/Voicemail/voicemail.db"

    struct Entry {
        let rowid: Int
        let date: Date?
        let sender: String?
        let durationSeconds: Int
    }

    struct Result {
        let written: [String]
        let outputDir: URL
    }

    /// Copies every voicemail recording into `dest` and writes `index.csv`.
    @discardableResult
    static func run(backup: Backup, to dest: URL, dryRun: Bool = false) throws -> Result {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let meta = try readMetadata(backup: backup, dryRun: dryRun)
        let audioFiles = try backup.files(domain: domain, pathLike: audioPathLike)

        var written: [String] = []
        var indexRows = [ExportFormat.csvRow(["file", "timestamp", "sender", "duration_seconds"])]

        for f in audioFiles.sorted(by: { $0.rel < $1.rel }) {
            let stem = (f.rel as NSString).lastPathComponent
                .replacingOccurrences(of: ".amr", with: "")
            let rowid = Int(stem)
            let entry = rowid.flatMap { id in meta.first { $0.rowid == id } }

            let base = fileName(for: entry, fallback: stem)
            let outURL = uniqueURL(in: dest, base: base, ext: "amr")
            try backup.readData(f).write(to: outURL)
            written.append(outURL.lastPathComponent)

            indexRows.append(ExportFormat.csvRow([
                outURL.lastPathComponent,
                entry?.date.map(ExportFormat.iso8601) ?? "",
                entry?.sender ?? "",
                String(entry?.durationSeconds ?? 0),
            ]))
        }

        if written.isEmpty, dryRun {
            log("no .amr recordings found under \(domain)/Library/Voicemail/")
        }
        try Data((indexRows.joined(separator: "\n") + "\n").utf8)
            .write(to: dest.appending(path: "index.csv"))

        return Result(written: written, outputDir: dest)
    }

    /// Reads per-voicemail metadata from `voicemail.db`. Missing/unencrypted
    /// databases yield an empty list (audio is still exported with raw names).
    static func readMetadata(backup: Backup, dryRun: Bool) throws -> [Entry] {
        guard let file = try backup.files(domain: domain, pathLike: dbPathLike).first else {
            if dryRun { log("voicemail.db not found; exporting audio with raw names") }
            return []
        }
        let db: Sqlite
        do { db = try backup.openSqlite(file) }
        catch {
            if dryRun { log("voicemail.db could not be opened: \(error)") }
            return []
        }
        guard let rows = try? db.query(
            "SELECT ROWID AS rowid, date, sender, duration FROM voicemail")
        else {
            if dryRun { log("voicemail table not present in voicemail.db") }
            return []
        }
        return rows.compactMap { row in
            guard let rowid = row.int("rowid") else { return nil }
            // `date` is Unix epoch seconds (not Core Data reference date).
            let date = row.int("date").map { Date(timeIntervalSince1970: Double($0)) }
            return Entry(
                rowid: rowid,
                date: date,
                sender: row.string("sender"),
                durationSeconds: row.int("duration") ?? 0)
        }
    }

    private static func fileName(for entry: Entry?, fallback: String) -> String {
        let stamp = entry?.date.map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd_HHmm"
            return f.string(from: $0)
        }
        let sender = entry?.sender.flatMap { $0.isEmpty ? nil : $0 }
        let parts = [stamp, sender].compactMap { $0 }
        return ExportFormat.safeFileName(parts.isEmpty ? fallback : parts.joined(separator: "_"),
                                         fallback: "voicemail-\(fallback)")
    }

    private static func uniqueURL(in dest: URL, base: String, ext: String) -> URL {
        var candidate = dest.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dest.appending(path: "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write("voicemail: \(message)\n".data(using: .utf8)!)
    }
}
