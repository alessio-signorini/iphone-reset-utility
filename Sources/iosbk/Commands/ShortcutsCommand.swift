import Foundation
import ArgumentParser

struct ShortcutsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shortcuts",
        abstract: "Shortcuts as individual .shortcut files",
        subcommands: [ShortcutsExportCommand.self])
}

struct ShortcutsExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write each Shortcut to its own .shortcut file",
        discussion: """
        The reconstructed .shortcut files are unsigned. To re-import them, \
        enable Settings → Shortcuts → Advanced → "Allow Untrusted Shortcuts", \
        then open each file and tap to add it. (Signing into the same iCloud \
        account is the simplest way to restore shortcuts; this export is the \
        offline alternative.)
        """)

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output directory (default: shortcuts)")
    var dir: String = "shortcuts"

    func run() throws {
        let backup = try options.resolveBackup()
        let result = try ShortcutsExport.run(
            backup: backup, to: URL(fileURLWithPath: dir), dryRun: options.dryRun)
        print("Exported \(result.written.count) shortcut(s) to \(dir)")
    }
}

