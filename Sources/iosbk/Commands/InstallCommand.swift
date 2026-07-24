import Foundation
import ArgumentParser

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install curated apps or a merged .mobileconfig profile.",
        subcommands: [InstallAppsCommand.self, InstallProfileCommand.self])
}

struct InstallAppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "Print (or run) install commands for a curated apps.yml.")

    @Option(name: .customLong("from"), help: "Curated apps.yml produced by `iosbk curate apps`.")
    var from: String

    @Option(name: .customLong("strategy"), help: "cfgutil | appstore-open")
    var strategy: AppsPlugin.InstallStrategy

    @Option(name: .customLong("ipa-dir"), help: "Directory of <bundleID>.ipa files (required for --strategy cfgutil).")
    var ipaDir: String?

    @Flag(name: .customLong("run"), help: "Actually execute the commands instead of just printing them.")
    var shouldRun: Bool = false

    func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: from))
        let apps = try AppsYAML.decode(data)
        let ipaDirURL = ipaDir.map { URL(fileURLWithPath: $0) }
        let (commands, warnings) = AppsPlugin.restoreCommands(apps: apps, strategy: strategy, ipaDir: ipaDirURL)

        for warning in warnings {
            FileHandle.standardError.write("warning: \(warning)\n".data(using: .utf8)!)
        }
        try CommandRunner.emit(commands, run: shouldRun)
    }
}

extension AppsPlugin.InstallStrategy: ExpressibleByArgument {}

struct InstallProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Print (or run) `cfgutil install-profile` for a merged .mobileconfig.")

    @Argument(help: "Path to a .mobileconfig produced by `iosbk profile`.")
    var path: String

    @Flag(name: .customLong("run"), help: "Actually execute the command instead of just printing it.")
    var shouldRun: Bool = false

    func run() throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("No such file: \(path)")
        }
        try CommandRunner.emit(["cfgutil install-profile \"\(path)\""], run: shouldRun)
    }
}
