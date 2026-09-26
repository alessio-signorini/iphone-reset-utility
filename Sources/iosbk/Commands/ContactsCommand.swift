import Foundation
import ArgumentParser

struct ContactsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Contacts as one multi-vCard .vcf",
        subcommands: [ContactsExportCommand.self])
}

struct ContactsExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write all contacts to a single .vcf file",
        discussion: "AirDrop the .vcf to your iPhone and tap \"Add All N Contacts\" to import them in one step.")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output .vcf path (default: contacts.vcf)")
    var output: String = "contacts.vcf"

    func run() throws {
        let backup = try options.resolveBackup()
        let result = try ContactsExport.run(
            backup: backup, to: URL(fileURLWithPath: output), dryRun: options.dryRun)
        print("Exported \(result.contactCount) contact(s) to \(output)")
    }
}
