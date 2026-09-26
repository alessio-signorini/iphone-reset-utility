import Foundation
import ArgumentParser

struct BookmarksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bookmarks",
        abstract: "Safari bookmarks as Netscape HTML",
        subcommands: [BookmarksDumpCommand.self])
}

struct BookmarksDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Write Safari bookmarks to a Netscape-format bookmarks.html",
        discussion: "iOS has no on-device import: open this file in Safari on a Mac (File → Import From → Bookmarks HTML File) and let iCloud sync the bookmarks back to the iPhone.")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output .html path (default: bookmarks.html)")
    var output: String = "bookmarks.html"

    func run() throws {
        let backup = try options.resolveBackup()
        let result = try BookmarksExport.run(
            backup: backup, to: URL(fileURLWithPath: output), dryRun: options.dryRun)
        print("Dumped \(result.bookmarkCount) bookmark(s) to \(output)")
    }
}
