import Foundation
import Testing
@testable import iosbk

@Suite("CallHistoryExport")
struct CallHistoryExportTests {
    private func backup() throws -> Backup {
        let db = try Fixture.sqliteFile(
            domain: CallHistoryExport.domain,
            rel: CallHistoryExport.pathLike
        ) { w in
            try w.exec("""
                CREATE TABLE ZCALLRECORD (
                    Z_PK INTEGER PRIMARY KEY, ZDATE INTEGER, ZADDRESS TEXT,
                    ZDURATION INTEGER, ZORIGINATED INTEGER, ZANSWERED INTEGER, ZCALLTYPE INTEGER)
                """)
            // ZDATE 0 == 2001-01-01T00:00:00Z on the Cocoa reference date.
            try w.exec(
                "INSERT INTO ZCALLRECORD (ZDATE, ZADDRESS, ZDURATION, ZORIGINATED, ZANSWERED, ZCALLTYPE) VALUES (?, ?, ?, ?, ?, ?)",
                bindings: [.int(0), .text("+15551234567"), .int(65), .int(1), .int(1), .int(1)])
            try w.exec(
                "INSERT INTO ZCALLRECORD (ZDATE, ZADDRESS, ZDURATION, ZORIGINATED, ZANSWERED, ZCALLTYPE) VALUES (?, ?, ?, ?, ?, ?)",
                bindings: [.int(0), .text("+15559998888"), .int(0), .int(0), .int(0), .int(1)])
        }
        return try Fixture.build([db])
    }

    @Test("reads call records and formats a CSV with direction/address/duration")
    func exportsCsv() throws {
        let calls = try CallHistoryExport.read(backup: try backup(), dryRun: false)
        #expect(calls.count == 2)

        let csv = CallHistoryExport.csv(calls)
        let lines = csv.split(separator: "\n")
        #expect(lines.first == "timestamp,direction,address,duration_seconds,answered")
        #expect(csv.contains("2001-01-01T00:00:00Z,outgoing,+15551234567,65,yes"))
        #expect(csv.contains("2001-01-01T00:00:00Z,incoming,+15559998888,0,no"))
    }

    @Test("returns empty when CallHistory database is absent")
    func emptyWhenMissing() throws {
        let calls = try CallHistoryExport.read(backup: try Fixture.emptyBackup(), dryRun: false)
        #expect(calls.isEmpty)
    }
}
