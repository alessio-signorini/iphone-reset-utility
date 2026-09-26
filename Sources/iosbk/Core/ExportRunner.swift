import Foundation

/// A `(domain, relativePath-LIKE-pattern)` selector for an export/dump preset.
struct ExportSpec {
    let domain: String?
    let pathLike: String?
}

/// Shared runner: applies each spec in order, writing decrypted files under
/// `output`, and prints a per-spec summary. Used by the file-copy-style
/// export/dump commands (photos, messages, health, notes, …).
enum ExportRunner {
    static func run(_ specs: [ExportSpec], backup: Backup, output: String, label: String, verb: String = "Exported") throws {
        let dest = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var total = 0
        for spec in specs {
            total += try backup.exportFiles(domain: spec.domain, pathLike: spec.pathLike, to: dest)
        }
        if total == 0 {
            FileHandle.standardError.write(
                "\(label): no matching files found — this data may be absent, or (for encrypted backups) only present when the right password is supplied.\n"
                    .data(using: .utf8)!)
        }
        print("\(verb) \(total) \(label) file(s) to \(output)")
    }
}
