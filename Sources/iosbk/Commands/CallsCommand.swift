import Foundation
import ArgumentParser

struct CallsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calls",
        abstract: "Call history as CSV",
        subcommands: [CallsDumpCommand.self])
}

struct CallsDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Write call history to a CSV file",
        discussion: "No supported way to re-import call history onto the device.")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output .csv path (default: calls.csv)")
    var output: String = "calls.csv"

    func run() throws {
        let backup = try options.resolveBackup()
        let result = try CallHistoryExport.run(
            backup: backup, to: URL(fileURLWithPath: output), dryRun: options.dryRun)
        print("Dumped \(result.callCount) call(s) to \(output)")
    }
}
