import Foundation
import ArgumentParser

struct VoicemailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voicemail",
        abstract: "Voicemail audio + index",
        subcommands: [VoicemailDumpCommand.self])
}

struct VoicemailDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Write .amr recordings (named by date/sender) plus an index.csv")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output directory (default: voicemail)")
    var dir: String = "voicemail"

    func run() throws {
        let backup = try options.resolveBackup()
        let result = try VoicemailExport.run(
            backup: backup, to: URL(fileURLWithPath: dir), dryRun: options.dryRun)
        print("Dumped \(result.written.count) voicemail recording(s) to \(dir)")
    }
}
