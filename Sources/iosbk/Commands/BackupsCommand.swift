import Foundation
import ArgumentParser

struct BackupsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backups",
        abstract: "List detected backups under ~/Library/Application Support/MobileSync/Backup")

    @Option(name: .customLong("root"), help: "Backup root directory (default: ~/Library/Application Support/MobileSync/Backup)")
    var root: String?

    func run() throws {
        let rootURL = root.map { URL(fileURLWithPath: $0) } ?? Backup.defaultRoot
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            print("No backups found under \(rootURL.path)")
            return
        }

        let backups = entries.filter { fm.fileExists(atPath: $0.appending(path: "Manifest.db").path) }
        if backups.isEmpty {
            print("No backups found under \(rootURL.path)")
            return
        }

        for dir in backups.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let info = Self.readInfoPlist(dir)
            let device = (info?["Device Name"] as? String) ?? "unknown device"
            let product = (info?["Product Type"] as? String).map { " (\($0))" } ?? ""
            let date = (info?["Last Backup Date"] as? Date).map { "\($0)" } ?? "unknown date"
            let encrypted = (try? Backup(dir: dir)) == nil
            print("\(dir.lastPathComponent)  \(device)\(product)  last backup: \(date)\(encrypted ? "  [encrypted]" : "")  \(dir.path)")
        }
    }

    /// `Info.plist` sits at the top of the backup directory (unlike the
    /// indexed backup content) so it's read directly, not via `Backup`.
    private static func readInfoPlist(_ dir: URL) -> [String: Any]? {
        let path = dir.appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? Plist.read(data)
    }
}
