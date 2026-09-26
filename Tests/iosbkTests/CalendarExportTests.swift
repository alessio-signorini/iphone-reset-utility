import Foundation
import Testing
@testable import iosbk

@Suite("CalendarExport")
struct CalendarExportTests {
    private func backup() throws -> Backup {
        let db = try Fixture.sqliteFile(
            domain: CalendarExport.domain,
            rel: CalendarExport.pathLike
        ) { w in
            try w.exec("""
                CREATE TABLE CalendarItem (
                    ROWID INTEGER PRIMARY KEY, summary TEXT, start_date INTEGER,
                    end_date INTEGER, all_day INTEGER, due_date INTEGER, completed INTEGER)
                """)
            // An event (has start_date). 3600 == 2001-01-01T01:00:00Z.
            try w.exec(
                "INSERT INTO CalendarItem (summary, start_date, end_date, all_day) VALUES (?, ?, ?, ?)",
                bindings: [.text("Team Meeting"), .int(3600), .int(7200), .int(0)])
            // An all-day event.
            try w.exec(
                "INSERT INTO CalendarItem (summary, start_date, end_date, all_day) VALUES (?, ?, ?, ?)",
                bindings: [.text("Holiday"), .int(86400), .int(172800), .int(1)])
            // A reminder (no start_date).
            try w.exec(
                "INSERT INTO CalendarItem (summary, completed) VALUES (?, ?)",
                bindings: [.text("Buy milk"), .int(0)])
        }
        return try Fixture.build([db])
    }

    @Test("exports calendar events as VEVENTs, honouring all-day")
    func exportsEvents() throws {
        let events = try CalendarExport.readEvents(backup: try backup(), dryRun: false)
        #expect(events.count == 2)

        let ics = CalendarExport.calendarICS(events)
        #expect(ics.contains("BEGIN:VCALENDAR"))
        #expect(ics.contains("BEGIN:VEVENT"))
        #expect(ics.contains("SUMMARY:Team Meeting"))
        #expect(ics.contains("DTSTART:20010101T010000Z"))
        #expect(ics.contains("DTSTART;VALUE=DATE:20010102"))
        #expect(ics.contains("END:VCALENDAR"))
    }

    @Test("exports reminders as VTODOs")
    func exportsReminders() throws {
        let reminders = try CalendarExport.readReminders(backup: try backup(), dryRun: false)
        #expect(reminders.count == 1)

        let ics = CalendarExport.remindersICS(reminders)
        #expect(ics.contains("BEGIN:VTODO"))
        #expect(ics.contains("SUMMARY:Buy milk"))
        #expect(ics.contains("STATUS:NEEDS-ACTION"))
    }

    @Test("returns empty when Calendar database is absent")
    func emptyWhenMissing() throws {
        let events = try CalendarExport.readEvents(backup: try Fixture.emptyBackup(), dryRun: false)
        #expect(events.isEmpty)
    }
}
