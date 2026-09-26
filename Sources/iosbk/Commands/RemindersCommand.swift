import Foundation
import ArgumentParser

struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Reminders as .ics (VTODO)",
        subcommands: [RemindersDumpCommand.self])
}

struct RemindersDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Write reminders to an .ics file (best-effort)",
        discussion: "iOS has no reliable local VTODO import — this file is for archival or import into a CalDAV/desktop client.")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output .ics path (default: reminders.ics)")
    var output: String = "reminders.ics"

    func run() throws {
        let backup = try options.resolveBackup()
        let result = try CalendarExport.runReminders(
            backup: backup, to: URL(fileURLWithPath: output), dryRun: options.dryRun)
        print("Dumped \(result.count) reminder(s) to \(output)")
    }
}
