import Foundation
import ArgumentParser

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show everything a backup contains — plugin items and exportable file data")

    @OptionGroup var options: BackupOptions

    private struct Row {
        let key: String
        let description: String
        let result: Result<Int, Error>
    }

    func run() throws {
        let backup = try options.resolveBackup()
        let rows = buildRows(backup: backup)
        printTable(rows)
    }

    private func buildRows(backup: Backup) -> [Row] {
        var rows: [Row] = []

        // Plugin-based (apps, webclips, wifi, accounts, …)
        for plugin in Registry.all {
            rows.append(Row(
                key: plugin.key,
                description: plugin.summary,
                result: Result { try plugin.extract(backup, dryRun: options.dryRun).count }
            ))
        }

        // File-based data
        let fileEntries: [(key: String, desc: String, counter: () throws -> Int)] = [
            ("photos",   "Camera Roll photos & videos",
             { try backup.files(domain: "CameraRollDomain", pathLike: "Media/DCIM/%").count }),
            ("wallet",   "Wallet passes",
             { try WalletExport.countBundles(backup: backup) }),
            ("messages", "SMS & iMessage database files",
             { try backup.files(domain: "HomeDomain", pathLike: "Library/SMS/%").count }),
            ("notes",    "Notes store files",
             { try backup.files(domain: "AppDomainGroup-group.com.apple.notes", pathLike: "NoteStore.sqlite%").count
                 + backup.files(domain: "HomeDomain", pathLike: "Library/Notes/%").count }),
            ("health",   "Health databases",
             { try backup.files(domain: "HealthDomain", pathLike: "Health/%").count }),
        ]

        for entry in fileEntries {
            rows.append(Row(key: entry.key, description: entry.desc,
                            result: Result { try entry.counter() }))
        }

        return rows
    }

    private func printTable(_ rows: [Row]) {
        let keyWidth  = max(rows.map(\.key.count).max() ?? 8, 3)
        let descWidth = max(rows.map(\.description.count).max() ?? 20, 11)

        func pad(_ s: String, _ w: Int) -> String {
            s + String(repeating: " ", count: max(0, w - s.count))
        }

        let header = "  \(pad("key", keyWidth))  \(pad("description", descWidth))  count"
        let sep    = "  " + String(repeating: "─", count: keyWidth + 2 + descWidth + 2 + 5)

        print(header)
        print(sep)
        for row in rows {
            let k = pad(row.key, keyWidth)
            let d = pad(row.description, descWidth)
            switch row.result {
            case .success(let n):
                print("  \(k)  \(d)  \(String(format: "%5d", n))")
            case .failure(let e):
                print("  \(k)  \(d)  error: \(e.localizedDescription)")
            }
        }
        print(sep)
    }
}
