import Foundation

/// Exports call history from a backup's `CallHistory.storedata` into a CSV
/// file (archival only — iOS has no supported re-import for call history).
///
/// // VERIFY: the `ZCALLRECORD` schema (`ZDATE`, `ZADDRESS`, `ZDURATION`,
/// `ZORIGINATED`, `ZANSWERED`, `ZCALLTYPE`) is stable on modern iOS but
/// should be confirmed against a real backup and recorded in the PR under
/// "Verified on-device".
enum CallHistoryExport {
    static let domain = "HomeDomain"
    static let pathLike = "Library/CallHistoryDB/CallHistory.storedata"

    struct Call {
        let date: Date?
        let address: String
        let durationSeconds: Int
        let outgoing: Bool
        let answered: Bool
        let callType: Int
    }

    struct Result {
        let callCount: Int
        let outputFile: URL
    }

    @discardableResult
    static func run(backup: Backup, to output: URL, dryRun: Bool = false) throws -> Result {
        let calls = try read(backup: backup, dryRun: dryRun)
        let csv = csv(calls)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(csv.utf8).write(to: output)
        return Result(callCount: calls.count, outputFile: output)
    }

    static func read(backup: Backup, dryRun: Bool) throws -> [Call] {
        guard let file = try backup.files(domain: domain, pathLike: pathLike).first else {
            if dryRun { log("CallHistory.storedata not found in \(domain)") }
            return []
        }
        let db: Sqlite
        do { db = try backup.openSqlite(file) }
        catch {
            if dryRun { log("CallHistory.storedata could not be opened: \(error)") }
            return []
        }

        guard let rows = try? db.query("""
            SELECT ZDATE AS date, ZADDRESS AS address, ZDURATION AS duration,
                   ZORIGINATED AS originated, ZANSWERED AS answered, ZCALLTYPE AS type
            FROM ZCALLRECORD ORDER BY ZDATE DESC
            """)
        else {
            if dryRun { log("ZCALLRECORD table not present (unencrypted backups omit call data)") }
            return []
        }

        return rows.map { row in
            // ZADDRESS is stored as a blob of UTF-8 phone-number bytes.
            let address: String
            if let s = row.string("address") {
                address = s
            } else if let d = row.data("address"), let s = String(data: d, encoding: .utf8) {
                address = s
            } else {
                address = ""
            }
            let dateVal = (row["date"] as? Double) ?? (row.int("date").map(Double.init))
            return Call(
                date: dateVal.map(ExportFormat.date(fromCocoa:)),
                address: address,
                durationSeconds: Int((row["duration"] as? Double) ?? Double(row.int("duration") ?? 0)),
                outgoing: (row.int("originated") ?? 0) == 1,
                answered: (row.int("answered") ?? 0) == 1,
                callType: row.int("type") ?? 0)
        }
    }

    static func csv(_ calls: [Call]) -> String {
        var lines = [ExportFormat.csvRow(["timestamp", "direction", "address", "duration_seconds", "answered"])]
        for c in calls {
            lines.append(ExportFormat.csvRow([
                c.date.map(ExportFormat.iso8601) ?? "",
                c.outgoing ? "outgoing" : "incoming",
                c.address,
                String(c.durationSeconds),
                c.answered ? "yes" : "no",
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write("calls: \(message)\n".data(using: .utf8)!)
    }
}
