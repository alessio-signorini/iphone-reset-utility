import Foundation

/// Shared formatting helpers for the file-export services (contacts → vCard,
/// calls → CSV, calendar/reminders → iCalendar, …). These are pure functions
/// with no backup/IO dependency so they can be unit-tested directly.
enum ExportFormat {
    /// Seconds between the Unix epoch (1970) and the Cocoa/Core Data
    /// reference date (2001-01-01 00:00:00 UTC). iOS databases store their
    /// timestamps as `Double` seconds since 2001.
    static let cocoaEpochOffset: TimeInterval = 978_307_200

    /// Converts a Core Data reference-date timestamp to a `Date`.
    static func date(fromCocoa seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds + cocoaEpochOffset)
    }

    /// ISO-8601 (UTC) rendering, e.g. `2025-01-31T09:15:00Z`.
    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// iCalendar UTC date-time, e.g. `20250131T091500Z`.
    static func icsDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// iCalendar all-day `VALUE=DATE`, e.g. `20250131` (in UTC).
    static func icsDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    /// Escapes a value for a single CSV field (RFC 4180): wraps in quotes and
    /// doubles embedded quotes when the value contains a comma, quote, or
    /// newline.
    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Joins a CSV row from already-raw fields.
    static func csvRow(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    /// Escapes text for a vCard/iCalendar value: backslash, then comma,
    /// semicolon, and newline, per RFC 5545 / RFC 6350.
    static func icalEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    /// Minimal HTML text escaping for Netscape bookmark output.
    static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Makes a string safe to use as a file name: replaces path separators
    /// and control characters, collapses whitespace, caps the length.
    static func safeFileName(_ s: String, fallback: String = "item") -> String {
        let mapped = s.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" || scalar.value < 0x20 {
                return "_"
            }
            return Character(scalar)
        }
        let collapsed = String(mapped).components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let trimmed = String(collapsed.prefix(80))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        return trimmed.isEmpty ? fallback : trimmed
    }
}
