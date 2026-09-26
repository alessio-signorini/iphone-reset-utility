import Foundation
import ArgumentParser

struct MessagesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Messages, raw sms.db + attachments",
        subcommands: [MessagesDumpCommand.self])
}

struct MessagesDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Decrypt and copy the Messages database + attachments",
        discussion: "Open sms.db in any SQLite viewer, or use a third-party Messages export tool. There is no supported way to push messages back onto the device.")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output directory (default: messages)")
    var dir: String = "messages"

    func run() throws {
        let backup = try options.resolveBackup()
        try ExportRunner.run(
            [ExportSpec(domain: "HomeDomain", pathLike: "Library/SMS/%")],
            backup: backup, output: dir, label: "messages", verb: "Dumped")
    }
}
