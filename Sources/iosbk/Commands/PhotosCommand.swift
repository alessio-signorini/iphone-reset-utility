import Foundation
import ArgumentParser

struct PhotosCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photos",
        abstract: "Photos, the Camera Roll (DCIM)",
        subcommands: [PhotosExportCommand.self])
}

struct PhotosExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Decrypt and copy the Camera Roll so you can AirDrop/Finder-import it back")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output directory (default: photos)")
    var dir: String = "photos"

    func run() throws {
        let backup = try options.resolveBackup()
        try ExportRunner.run(
            [ExportSpec(domain: "CameraRollDomain", pathLike: "Media/DCIM/%")],
            backup: backup, output: dir, label: "photo")
    }
}
