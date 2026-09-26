import Foundation
import ArgumentParser

struct HealthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Health data, raw healthdb*.sqlite",
        subcommands: [HealthDumpCommand.self])
}

struct HealthDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Decrypt and copy the Health databases",
        discussion: "Open the dumped .sqlite files in any SQLite viewer for archival or analysis. There is no supported way to push Health data back onto the device.")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output directory (default: health)")
    var dir: String = "health"

    func run() throws {
        let backup = try options.resolveBackup()
        try ExportRunner.run(
            [ExportSpec(domain: "HealthDomain", pathLike: "Health/%")],
            backup: backup, output: dir, label: "health", verb: "Dumped")
    }
}
