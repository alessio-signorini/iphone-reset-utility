import Foundation

/// Minimal, hand-rolled YAML codec for `apps.yml`.
///
/// `apps.yml` has one job — be a human-editable list of
/// `{bundleID, name, storeID, keep}` records — so a full YAML parser would
/// be overkill and another dependency. This codec only understands that one
/// shape.
enum AppsYAML {
    enum YAMLError: Error, CustomStringConvertible {
        case malformed(String)
        var description: String {
            switch self { case .malformed(let msg): return "malformed apps.yml: \(msg)" }
        }
    }

    static func encode(_ apps: [CuratedApp]) -> Data {
        var lines = ["apps:"]
        if apps.isEmpty {
            lines.append("  []")
        }
        for app in apps {
            lines.append("  - bundleID: \(scalar(app.bundleID))")
            lines.append("    name: \(scalar(app.name))")
            lines.append("    storeID: \(scalar(app.storeID))")
            lines.append("    keep: \(app.keep)")
        }
        return (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
    }

    static func decode(_ data: Data) throws -> [CuratedApp] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw YAMLError.malformed("not UTF-8")
        }
        var apps: [CuratedApp] = []
        var current: [String: String] = [:]

        func flush() throws {
            guard !current.isEmpty else { return }
            guard let bundleID = current["bundleID"] else {
                throw YAMLError.malformed("entry missing bundleID")
            }
            let name = current["name"].flatMap { $0 == "null" ? nil : $0 }
            let storeID = current["storeID"].flatMap { $0 == "null" ? nil : Int($0) }
            let keep = (current["keep"] ?? "true") == "true"
            apps.append(CuratedApp(bundleID: bundleID, name: name, storeID: storeID, keep: keep))
            current = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "apps:" || trimmed == "[]" { continue }

            var body = trimmed
            if body.hasPrefix("- ") {
                try flush()
                body = String(body.dropFirst(2))
            }
            guard let colon = body.firstIndex(of: ":") else { continue }
            let keyPart = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var valuePart = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if valuePart.hasPrefix("\"") && valuePart.hasSuffix("\"") && valuePart.count >= 2 {
                valuePart = String(valuePart.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
            current[keyPart] = valuePart
        }
        try flush()
        return apps
    }

    private static func scalar(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func scalar(_ s: String?) -> String {
        guard let s else { return "null" }
        return scalar(s)
    }

    private static func scalar(_ i: Int?) -> String {
        guard let i else { return "null" }
        return "\(i)"
    }
}
