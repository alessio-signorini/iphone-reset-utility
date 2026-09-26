import Foundation
import ArgumentParser

struct BluetoothCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bluetooth",
        abstract: "Paired Bluetooth device inventory",
        subcommands: [BluetoothDumpCommand.self])
}

struct BluetoothDumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Write previously-paired Bluetooth devices to a text file",
        discussion: "Pairings can't be restored — this list is an inventory of devices to re-pair by hand.")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output .txt path (default: bluetooth-devices.txt)")
    var output: String = "bluetooth-devices.txt"

    func run() throws {
        let backup = try options.resolveBackup()
        let result = try BluetoothExport.run(
            backup: backup, to: URL(fileURLWithPath: output), dryRun: options.dryRun)
        print("Dumped \(result.devices.count) paired device(s) to \(output)")
    }
}
