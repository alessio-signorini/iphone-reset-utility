import Foundation

/// Minimal, hand-rolled YAML codec for the `curate` files (`wifi.yml`,
/// `accounts.yml`, …).
///
/// Like `AppsYAML`, these files have one job — be a human-editable list of
/// flat `{key: value}` records under a single root key — so a full YAML
/// parser would be overkill. This codec understands exactly that shape:
///
/// ```yaml
/// wifi:
///   - ssid: "HomeNet"
///     encryption: "WPA2"
///     hidden: false
///     keep: true
/// ```
///
/// The root key (`wifi`, `accounts`, …) identifies the record type, so a
/// consumer can load a curated file without being told which kind it is.
/// Whole-line `#` comments and deleted records are both honoured, so users
/// can prune the list either way.
enum CurateYAML {
    enum YAMLError: Error, CustomStringConvertible {
        case malformed(String)
        var description: String {
            switch self { case .malformed(let msg): return "malformed curate file: \(msg)" }
        }
    }

    /// Serializes `records` (ordered key/value pairs, values already quoted
    /// via `quoted`/`bool`) under `root:`.
    static func encode(root: String, records: [[(key: String, value: String)]]) -> Data {
        var lines = ["\(root):"]
        if records.isEmpty { lines.append("  []") }
        for record in records {
            var first = true
            for (key, value) in record {
                lines.append("\(first ? "  - " : "    ")\(key): \(value)")
                first = false
            }
        }
        return (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
    }

    /// Parses a curate file into its root key and a list of string records.
    /// The file must have exactly one root section — use `decodeSections`
    /// for files with several (e.g. `profile.yml`).
    static func decode(_ data: Data) throws -> (root: String, records: [[String: String]]) {
        let sections = try decodeSections(data)
        guard sections.count == 1 else {
            throw YAMLError.malformed("expected exactly one root key, found \(sections.count)")
        }
        return sections[0]
    }

    /// Parses a curate file that may have several top-level sections, each
    /// introduced by an unindented `key:` line (e.g. `profile.yml`'s
    /// `webclips:` / `wifi:` / `accounts:` / `certs:`), returning each
    /// section's root key and records in file order.
    static func decodeSections(_ data: Data) throws -> [(root: String, records: [[String: String]])] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw YAMLError.malformed("not UTF-8")
        }
        var sections: [(root: String, records: [[String: String]])] = []
        var root: String?
        var records: [[String: String]] = []
        var current: [String: String] = [:]

        func flushRecord() {
            if !current.isEmpty { records.append(current); current = [:] }
        }
        func flushSection() {
            flushRecord()
            if let root { sections.append((root, records)) }
            records = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // An unindented "key:" line starts a new section.
            if !line.hasPrefix(" "), trimmed.hasSuffix(":") {
                flushSection()
                root = String(trimmed.dropLast())
                continue
            }
            if trimmed == "[]" { continue }

            var body = trimmed
            if body.hasPrefix("- ") {
                flushRecord()
                body = String(body.dropFirst(2))
            }
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
            current[key] = value
        }
        flushSection()

        guard !sections.isEmpty else { throw YAMLError.malformed("missing root key") }
        return sections
    }

    /// Quotes a string scalar (or emits `null`), escaping embedded quotes.
    static func quoted(_ s: String?) -> String {
        guard let s else { return "null" }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Emits a boolean scalar unquoted.
    static func bool(_ b: Bool) -> String { "\(b)" }
}
