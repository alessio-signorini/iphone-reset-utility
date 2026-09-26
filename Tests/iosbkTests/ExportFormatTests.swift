import Foundation
import Testing
@testable import iosbk

@Suite("ExportFormat")
struct ExportFormatTests {
    @Test("csvField quotes only when needed and doubles embedded quotes")
    func csvFieldEscaping() {
        #expect(ExportFormat.csvField("plain") == "plain")
        #expect(ExportFormat.csvField("a,b") == "\"a,b\"")
        #expect(ExportFormat.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(ExportFormat.csvField("line\nbreak") == "\"line\nbreak\"")
    }

    @Test("icalEscape escapes backslash, comma, semicolon, and newlines")
    func icalEscaping() {
        #expect(ExportFormat.icalEscape("a;b,c\\d") == "a\\;b\\,c\\\\d")
        #expect(ExportFormat.icalEscape("line1\nline2") == "line1\\nline2")
    }

    @Test("Core Data timestamps convert to the expected UTC instant")
    func cocoaDateConversion() {
        // 2001-01-01T00:00:00Z is 0 seconds on the Cocoa reference date.
        let epoch = ExportFormat.date(fromCocoa: 0)
        #expect(ExportFormat.iso8601(epoch) == "2001-01-01T00:00:00Z")
        #expect(ExportFormat.icsDateTime(epoch) == "20010101T000000Z")
        #expect(ExportFormat.icsDate(epoch) == "20010101")
    }

    @Test("safeFileName strips separators and collapses whitespace")
    func safeFileName() {
        #expect(ExportFormat.safeFileName("a/b:c") == "a_b_c")
        #expect(ExportFormat.safeFileName("  spaced   name ") == "spaced name")
        #expect(ExportFormat.safeFileName("", fallback: "x") == "x")
    }
}
