import Foundation
import Testing
@testable import iosbk

@Suite("BookmarksExport")
struct BookmarksExportTests {
    private func backup() throws -> Backup {
        let db = try Fixture.sqliteFile(
            domain: BookmarksExport.domain,
            rel: BookmarksExport.pathLike
        ) { w in
            try w.exec("""
                CREATE TABLE bookmarks (
                    id INTEGER PRIMARY KEY, parent INTEGER, title TEXT, url TEXT)
                """)
            // A root folder with one nested bookmark, plus a top-level bookmark.
            try w.exec("INSERT INTO bookmarks (id, parent, title) VALUES (?, ?, ?)",
                       bindings: [.int(1), .int(0), .text("Favorites")])
            try w.exec("INSERT INTO bookmarks (id, parent, title, url) VALUES (?, ?, ?, ?)",
                       bindings: [.int(2), .int(1), .text("Example"), .text("https://example.com")])
            try w.exec("INSERT INTO bookmarks (id, parent, title, url) VALUES (?, ?, ?, ?)",
                       bindings: [.int(3), .int(0), .text("Root & Link"), .text("https://root.com?a=1&b=2")])
        }
        return try Fixture.build([db])
    }

    @Test("builds a nested Netscape bookmark file")
    func exportsHtml() throws {
        let roots = try BookmarksExport.readTree(backup: try backup(), dryRun: false)
        #expect(BookmarksExport.countLeaves(roots) == 2)

        let html = BookmarksExport.html(roots)
        #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        #expect(html.contains("<DT><H3>Favorites</H3>"))
        #expect(html.contains("<DT><A HREF=\"https://example.com\">Example</A>"))
        // HTML-escaping of ampersands in title and URL.
        #expect(html.contains("Root &amp; Link"))
        #expect(html.contains("https://root.com?a=1&amp;b=2"))
    }

    @Test("returns empty when Bookmarks.db is absent")
    func emptyWhenMissing() throws {
        let roots = try BookmarksExport.readTree(backup: try Fixture.emptyBackup(), dryRun: false)
        #expect(roots.isEmpty)
    }
}
