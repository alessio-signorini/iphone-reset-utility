import Foundation
import ArgumentParser

struct ExtractCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Extract one or more plugins' items from a backup.")

    @Argument(help: "Plugin keys to extract, e.g. webclips wifi accounts apps")
    var keys: [String]

    @OptionGroup var options: BackupOptions

    @Flag(name: .customLong("json"), help: "Print items as JSON instead of one-line descriptions.")
    var json: Bool = false

    func run() throws {
        let backup = try options.resolveBackup()
        for key in keys {
            guard let plugin = Registry[key] else {
                throw ValidationError("Unknown plugin key: \(key). Available: \(Registry.all.map(\.key).joined(separator: ", "))")
            }
            let items = try plugin.extract(backup, dryRun: options.dryRun)
            if json {
                let data = try plugin.json(items)
                print(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                print("== \(key) (\(items.count)) ==")
                for item in items {
                    print(plugin.describe(item))
                }
            }
        }
    }
}
