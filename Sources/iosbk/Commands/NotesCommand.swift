import Foundation
import ArgumentParser

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Notes, one Markdown file per note",
        subcommands: [NotesDumpCommand.self])
}

struct NotesDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Dump Notes as individual files (one Markdown file per note)",
        discussion: "Writes one .md file per note (named after its dashed title, or its identifier / row id when untitled) plus an index.csv. Use --raw to copy the raw NoteStore.sqlite instead. Archival only — there is no supported way to push notes back onto the device.")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output directory (default: notes)")
    var dir: String = "notes"

    @Flag(name: .long, help: "Copy the raw NoteStore.sqlite store instead of extracting individual notes")
    var raw: Bool = false

    func run() throws {
        let backup = try options.resolveBackup()
        if raw {
            // Modern (group container) and legacy (HomeDomain) locations.
            try ExportRunner.run([
                ExportSpec(domain: NotesExport.domain, pathLike: "NoteStore.sqlite%"),
                ExportSpec(domain: "HomeDomain", pathLike: "Library/Notes/%"),
            ], backup: backup, output: dir, label: "notes", verb: "Dumped")
            return
        }
        let result = try NotesExport.run(
            backup: backup, to: URL(fileURLWithPath: dir), dryRun: options.dryRun)
        print("Dumped \(result.written.count) note(s) to \(dir)")
    }
}
