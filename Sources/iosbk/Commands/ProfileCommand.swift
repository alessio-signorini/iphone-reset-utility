import Foundation
import ArgumentParser

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Merge one or more plugins' payloads into a single .mobileconfig profile.")

    @Argument(help: "Plugin keys to include, e.g. webclips wifi accounts")
    var keys: [String]

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output .mobileconfig path.")
    var output: String

    @Option(name: .customLong("name"), help: "PayloadDisplayName for the merged profile.")
    var displayName: String = "iosbk restore"

    func run() throws {
        let backup = try options.resolveBackup()
        var payloads: [Payload] = []
        for key in keys {
            guard let plugin = Registry[key] else {
                throw ValidationError("Unknown plugin key: \(key). Available: \(Registry.all.map(\.key).joined(separator: ", "))")
            }
            let items = try plugin.extract(backup, dryRun: options.dryRun)
            payloads.append(contentsOf: plugin.payloads(items))
        }

        guard !payloads.isEmpty else {
            throw ValidationError("No payloads produced by \(keys.joined(separator: ", ")); nothing to write.")
        }

        let data = try ProfileBuilder.build(payloads, displayName: displayName)
        try data.write(to: URL(fileURLWithPath: output))
        print("Wrote \(payloads.count) payload(s) to \(output)")
    }
}
