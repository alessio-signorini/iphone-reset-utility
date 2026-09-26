import Foundation
import ArgumentParser

struct CalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Calendar events as .ics",
        subcommands: [CalendarExportCommand.self])
}

struct CalendarExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write calendar events to an .ics file",
        discussion: "AirDrop or email the .ics to your iPhone; iOS Calendar adds every event at once.")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output .ics path (default: calendar.ics)")
    var output: String = "calendar.ics"

    func run() throws {
        let backup = try options.resolveBackup()
        let result = try CalendarExport.runCalendar(
            backup: backup, to: URL(fileURLWithPath: output), dryRun: options.dryRun)
        print("Exported \(result.count) event(s) to \(output)")
    }
}
