import Foundation
import ArgumentParser

struct CurateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "curate",
        abstract: "Produce editable, curated output for a plugin.",
        subcommands: [CurateAppsCommand.self])
}

struct CurateAppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "Curate installed app bundle IDs into an editable apps.yml.")

    @OptionGroup var options: BackupOptions

    @Flag(name: .customLong("enrich"), help: "Resolve bundleID -> name + App Store id via the iTunes Lookup API (network call).")
    var enrich: Bool = false

    @Option(name: .shortAndLong, help: "Output YAML path.")
    var output: String = "apps.yml"

    func run() async throws {
        let backup = try options.resolveBackup()
        let bundleIDs = try AppsPlugin().extract(backup, dryRun: options.dryRun)
        let client: ITunesLookupClient? = enrich ? LiveITunesLookupClient() : nil
        let apps = await AppsPlugin.curate(bundleIDs: bundleIDs, client: client)
        let data = AppsYAML.encode(apps)
        try data.write(to: URL(fileURLWithPath: output))
        print("Wrote \(apps.count) app(s) to \(output)")
    }
}
