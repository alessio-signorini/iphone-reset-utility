import Foundation
import ArgumentParser

struct WalletCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wallet",
        abstract: "Wallet passes as ready-to-AirDrop .pkpass files",
        subcommands: [WalletExportCommand.self])
}

struct WalletExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Decrypt and pack Wallet passes into .pkpass files")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output directory (default: wallet)")
    var dir: String = "wallet"

    func run() throws {
        let backup = try options.resolveBackup()
        let dest = URL(fileURLWithPath: dir)
        let result = try WalletExport.run(backup: backup, to: dest)
        if result.written.isEmpty {
            FileHandle.standardError.write(
                "wallet: no passes found — the backup may have none, or (encrypted backups) the password may be wrong.\n"
                    .data(using: .utf8)!)
            return
        }
        print("Packed \(result.written.count) pass(es) into \(dir)"
            + (result.skipped > 0 ? " (\(result.skipped) skipped: no pass.json)" : ""))
        for name in result.written { print("  \(name)") }
        print("AirDrop the .pkpass files you want back to your iPhone, then tap each to add it to Wallet.")
    }
}
