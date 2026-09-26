import Foundation

/// Exports calendar events and reminders from a backup's `Calendar.sqlitedb`
/// as iCalendar (`.ics`) files.
///
/// Calendar events (`VEVENT`) re-import cleanly: AirDrop or email the `.ics`
/// and iOS Calendar adds every event at once. Reminders (`VTODO`) are
/// best-effort — iOS has no reliable local `VTODO` import, so the reminders
/// file is primarily for archival or import into a CalDAV/desktop client.
///
/// // VERIFY: the `CalendarItem` schema (`summary`, `start_date`, `end_date`,
/// `all_day`, `due_date`, `completed`) varies across iOS versions; this reads
/// defensively (a missing column/table yields an empty result, not a crash).
/// Confirm against a real backup and record in the PR under
/// "Verified on-device".
enum CalendarExport {
    static let domain = "HomeDomain"
    static let pathLike = "Library/Calendar/Calendar.sqlitedb"

    struct Event {
        let summary: String
        let start: Date?
        let end: Date?
        let allDay: Bool
    }

    struct Reminder {
        let summary: String
        let due: Date?
        let completed: Bool
    }

    struct Result {
        let count: Int
        let outputFile: URL
    }

    // MARK: - Calendar events

    @discardableResult
    static func runCalendar(backup: Backup, to output: URL, dryRun: Bool = false) throws -> Result {
        let events = try readEvents(backup: backup, dryRun: dryRun)
        try write(calendarICS(events), to: output)
        return Result(count: events.count, outputFile: output)
    }

    static func readEvents(backup: Backup, dryRun: Bool) throws -> [Event] {
        guard let db = try openDB(backup: backup, label: "calendar", dryRun: dryRun) else { return [] }
        guard let rows = try? db.query("""
            SELECT summary, start_date, end_date, all_day
            FROM CalendarItem WHERE start_date IS NOT NULL ORDER BY start_date
            """)
        else {
            if dryRun { log("calendar", "CalendarItem table not present (unencrypted backups omit calendar data)") }
            return []
        }
        return rows.compactMap { row in
            guard let summary = row.string("summary"), !summary.isEmpty else { return nil }
            return Event(
                summary: summary,
                start: cocoaDate(row["start_date"]),
                end: cocoaDate(row["end_date"]),
                allDay: (row.int("all_day") ?? 0) == 1)
        }
    }

    static func calendarICS(_ events: [Event]) -> String {
        var body = ""
        for e in events {
            body += "BEGIN:VEVENT\r\n"
            body += "UID:\(UUID().uuidString)@iosbk\r\n"
            if let start = e.start {
                body += e.allDay
                    ? "DTSTART;VALUE=DATE:\(ExportFormat.icsDate(start))\r\n"
                    : "DTSTART:\(ExportFormat.icsDateTime(start))\r\n"
            }
            if let end = e.end {
                body += e.allDay
                    ? "DTEND;VALUE=DATE:\(ExportFormat.icsDate(end))\r\n"
                    : "DTEND:\(ExportFormat.icsDateTime(end))\r\n"
            }
            body += "SUMMARY:\(ExportFormat.icalEscape(e.summary))\r\n"
            body += "END:VEVENT\r\n"
        }
        return wrap(body)
    }

    // MARK: - Reminders

    @discardableResult
    static func runReminders(backup: Backup, to output: URL, dryRun: Bool = false) throws -> Result {
        let reminders = try readReminders(backup: backup, dryRun: dryRun)
        try write(remindersICS(reminders), to: output)
        return Result(count: reminders.count, outputFile: output)
    }

    static func readReminders(backup: Backup, dryRun: Bool) throws -> [Reminder] {
        guard let db = try openDB(backup: backup, label: "reminders", dryRun: dryRun) else { return [] }
        // Reminders are CalendarItem rows without a start_date. `due_date` and
        // `completed` may be absent on some iOS versions — fall back to a
        // summary-only read so we still capture the reminder text.
        let rows = (try? db.query("""
            SELECT summary, due_date, completed FROM CalendarItem
            WHERE start_date IS NULL AND summary IS NOT NULL
            """))
            ?? (try? db.query("""
            SELECT summary FROM CalendarItem
            WHERE start_date IS NULL AND summary IS NOT NULL
            """))
        guard let rows else {
            if dryRun { log("reminders", "CalendarItem table not present (unencrypted backups omit reminder data)") }
            return []
        }
        return rows.compactMap { row in
            guard let summary = row.string("summary"), !summary.isEmpty else { return nil }
            return Reminder(
                summary: summary,
                due: cocoaDate(row["due_date"]),
                completed: (row.int("completed") ?? 0) != 0)
        }
    }

    static func remindersICS(_ reminders: [Reminder]) -> String {
        var body = ""
        for r in reminders {
            body += "BEGIN:VTODO\r\n"
            body += "UID:\(UUID().uuidString)@iosbk\r\n"
            if let due = r.due {
                body += "DUE:\(ExportFormat.icsDateTime(due))\r\n"
            }
            body += "SUMMARY:\(ExportFormat.icalEscape(r.summary))\r\n"
            body += "STATUS:\(r.completed ? "COMPLETED" : "NEEDS-ACTION")\r\n"
            body += "END:VTODO\r\n"
        }
        return wrap(body)
    }

    // MARK: - Helpers

    private static func openDB(backup: Backup, label: String, dryRun: Bool) throws -> Sqlite? {
        guard let file = try backup.files(domain: domain, pathLike: pathLike).first else {
            if dryRun { log(label, "Calendar.sqlitedb not found in \(domain)") }
            return nil
        }
        do { return try backup.openSqlite(file) }
        catch {
            if dryRun { log(label, "Calendar.sqlitedb could not be opened: \(error)") }
            return nil
        }
    }

    private static func cocoaDate(_ value: Any?) -> Date? {
        if let d = value as? Double, d > 0 { return ExportFormat.date(fromCocoa: d) }
        if let i = value as? Int, i > 0 { return ExportFormat.date(fromCocoa: Double(i)) }
        return nil
    }

    private static func wrap(_ body: String) -> String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//iosbk//EN\r\n" + body + "END:VCALENDAR\r\n"
    }

    private static func write(_ text: String, to output: URL) throws {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: output)
    }

    private static func log(_ label: String, _ message: String) {
        FileHandle.standardError.write("\(label): \(message)\n".data(using: .utf8)!)
    }
}
