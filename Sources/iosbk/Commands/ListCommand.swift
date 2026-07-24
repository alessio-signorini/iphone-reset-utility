import Foundation
import ArgumentParser

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List plugins and how many items each extracts from a backup.")

    @OptionGroup var options: BackupOptions

    func run() throws {
        let backup = try options.resolveBackup()
        for plugin in Registry.all {
            let count: Int
            do {
                count = try plugin.extract(backup, dryRun: options.dryRun).count
            } catch {
                print("\(plugin.key)\t\(plugin.summary)\terror: \(error)")
                continue
            }
            print("\(plugin.key)\t\(plugin.summary)\t\(count) item(s)")
        }
    }
}
