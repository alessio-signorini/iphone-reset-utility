import Foundation
import ArgumentParser

struct AppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "Curate, download, and install App Store apps",
        discussion: """
        Typical workflow:
          1. iosbk apps curate   — extract app list from backup → apps/list.yml
          2. Edit apps/list.yml  — set keep: false for apps you don't want
          3. iosbk apps download — fetch IPAs via ipatool → apps/ipa/
          4. iosbk apps install  — push IPAs to device via cfgutil
        """,
        subcommands: [AppsCurateCommand.self, AppsDownloadCommand.self, AppsInstallCommand.self])
}

extension AppsPlugin.InstallStrategy: ExpressibleByArgument {}

// MARK: - curate

struct AppsCurateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "curate",
        abstract: "Extract installed app bundle IDs and write an editable list.yml")

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Working directory for all apps assets (default: apps)")
    var dir: String = "apps"

    @Flag(name: .customLong("enrich"),
          help: "Resolve each bundleID to its name + App Store id via the iTunes Lookup API (network)")
    var enrich: Bool = false

    @Flag(name: .customLong("print-only"), help: "Print the YAML to stdout instead of writing to disk")
    var printOnly: Bool = false

    func run() async throws {
        let backup = try options.resolveBackup()
        let bundleIDs = try AppsPlugin().extract(backup, dryRun: options.dryRun)
        let client: ITunesLookupClient? = enrich ? LiveITunesLookupClient() : nil
        let apps = await AppsPlugin.curate(bundleIDs: bundleIDs, client: client)
        let data = AppsYAML.encode(apps)

        if printOnly {
            print(String(data: data, encoding: .utf8) ?? "")
            return
        }

        let dirURL = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let dest = dirURL.appending(path: "list.yml")
        try data.write(to: dest)
        print("Wrote \(apps.count) app(s) to \(dest.path)")
        print("Edit \(dest.path) — set keep: false for apps you don't want — then run: iosbk apps download --dir \"\(dir)\"")
    }
}

// MARK: - download

struct AppsDownloadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download IPAs via `ipatool` for every kept app in list.yml",
        discussion: "Requires: brew install ipatool && ipatool auth login --email <apple-id>")

    @Option(name: .shortAndLong, help: "Working directory for all apps assets (default: apps)")
    var dir: String = "apps"

    @Flag(name: .customLong("print-only"), help: "Print the ipatool commands instead of running them")
    var printOnly: Bool = false

    func run() throws {
        let dirURL = URL(fileURLWithPath: dir)
        let listURL = dirURL.appending(path: "list.yml")
        let data = try Data(contentsOf: listURL)
        let apps = try AppsYAML.decode(data)
        let kept = apps.filter(\.keep)

        guard !kept.isEmpty else {
            print("No apps marked keep: true in \(listURL.path).")
            return
        }

        if !printOnly {
            guard resolveExecutable("ipatool") != nil else {
                throw ValidationError(
                    "ipatool not found in PATH.\n" +
                    "  Install:       brew install ipatool\n" +
                    "  Authenticate:  ipatool auth login --email <your-apple-id>")
            }
        }

        let ipaDirURL = dirURL.appending(path: "ipa")
        var commands: [String] = ["mkdir -p \"\(ipaDirURL.path)\""]
        for app in kept {
            let label = app.name.map { "\($0) (\(app.bundleID))" } ?? app.bundleID
            commands.append(
                "ipatool download --bundle-id \"\(app.bundleID)\"" +
                " --output \"\(ipaDirURL.path)/\(app.bundleID).ipa\"" +
                "  # \(label)")
        }

        for warning in AppsPlugin.downloadWarnings(apps: apps) {
            FileHandle.standardError.write("warning: \(warning)\n".data(using: .utf8)!)
        }

        try CommandRunner.emit(commands, run: !printOnly)

        if !printOnly {
            print("\nDone. Run: iosbk apps install --dir \"\(dir)\"")
        }
    }

    private func resolveExecutable(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out?.isEmpty == false ? out : nil
    }
}

// MARK: - install

struct AppsInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install apps onto the device from a curated list.yml")

    @Option(name: .shortAndLong, help: "Working directory for all apps assets (default: apps)")
    var dir: String = "apps"

    @Option(name: .customLong("strategy"),
            help: "cfgutil (default) | appstore-open | html")
    var strategy: AppsPlugin.InstallStrategy = .cfgutil

    @Flag(name: .customLong("print-only"), help: "Print the commands instead of running them")
    var printOnly: Bool = false

    func run() throws {
        let dirURL = URL(fileURLWithPath: dir)
        let listURL = dirURL.appending(path: "list.yml")
        let data = try Data(contentsOf: listURL)
        let apps = try AppsYAML.decode(data)

        if strategy == .html {
            let dest = dirURL.appending(path: "list.html")
            let page = AppsPlugin.htmlPage(apps: apps)
            try page.write(to: dest, atomically: true, encoding: .utf8)
            print(dest.path)
            if !printOnly {
                try CommandRunner.emit(["open \"\(dest.path)\""], run: true)
            }
            return
        }

        let ipaDirURL = dirURL.appending(path: "ipa")
        let (commands, warnings) = AppsPlugin.restoreCommands(
            apps: apps, strategy: strategy, ipaDir: ipaDirURL)

        for warning in warnings {
            FileHandle.standardError.write("warning: \(warning)\n".data(using: .utf8)!)
        }
        try CommandRunner.emit(commands, run: !printOnly)
    }
}
