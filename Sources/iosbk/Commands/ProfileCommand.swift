import Foundation
import ArgumentParser

struct ProfileCommand: ParsableCommand {
    /// Plugin keys that contribute to a profile. Excludes `apps`, which
    /// restores via its own workflow (see `iosbk apps`) instead of a profile.
    static var profilePlugins: [AnyExtractorPlugin] {
        Registry.all.filter(\.buildsProfile)
    }

    /// Plugin keys + summaries, generated so the list can never drift out of
    /// sync with `Registry.all`.
    static var pluginKeyList: String {
        let width = profilePlugins.map(\.key.count).max() ?? 0
        return profilePlugins
            .map { plugin -> String in
                let padded = plugin.key.padding(toLength: width, withPad: " ", startingAt: 0)
                return "  \(padded)  \(plugin.summary)"
            }
            .joined(separator: "\n")
    }

    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Build and install a .mobileconfig from plugins",
        discussion: """
        iosbk profile curate   — extract plugin items into an editable profile.yml
        iosbk profile install  — build the .mobileconfig from it + the backup, install it

        PLUGIN KEYS (`iosbk list` shows what each finds in your backup):
        \(pluginKeyList)

        Examples:
          iosbk profile curate -o restore.yml
          iosbk profile install restore.yml --run

        Select what to include: pass --keys webclips,wifi,... to curate \
        (default: all). Edit the keep: true/false flags in the curated file \
        to fine-tune which items actually get installed.
        """,
        subcommands: [ProfileCurateCommand.self, ProfileInstallCommand.self])
}

struct ProfileCurateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "curate",
        abstract: "Extract plugin items from the backup into an editable profile.yml",
        discussion: """
        Writes profile.yml by default (override with -o): one section per \
        plugin, each item shown with the same description `iosbk list` \
        uses, plus a keep: true/false flag. Edit it, then run `iosbk \
        profile install` to build the actual .mobileconfig from the backup \
        and install it. Run `iosbk profile` (no arguments) for the plugin list.
        """)

    @Option(name: .customLong("keys"), help: "Comma-separated plugin keys to include (default: all; run `iosbk profile` to list them)")
    var keys: String?

    @OptionGroup var options: BackupOptions

    @Option(name: .shortAndLong, help: "Output curated YAML path")
    var output: String = "profile.yml"

    @Flag(name: .customLong("print-only"), help: "Print the YAML to stdout instead of writing to disk")
    var printOnly: Bool = false

    func run() throws {
        let selectedKeys: [String]
        if let keys {
            selectedKeys = keys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            selectedKeys = ProfileCommand.profilePlugins.map(\.key)
        }

        guard !selectedKeys.isEmpty else {
            throw ValidationError("Nothing to include: --keys resolved to zero plugins")
        }

        let backup = try options.resolveBackup()
        var sections: [(key: String, items: [CuratedItem])] = []
        var total = 0
        for key in selectedKeys {
            guard let plugin = Registry[key], plugin.buildsProfile else {
                throw ValidationError("Unknown plugin key: \(key). Available: \(ProfileCommand.profilePlugins.map(\.key).joined(separator: ", "))")
            }
            let items = try plugin.extract(backup, dryRun: options.dryRun)
            let ordered = key == WebClipsPlugin().key ? Self.webClipsWebFirst(items) : items
            let curated = ordered.map { CuratedItem(description: plugin.describe($0), keep: true) }
            sections.append((key, curated))
            total += curated.count

            if key == WebClipsPlugin().key {
                let shortcutClips = ordered.compactMap { $0 as? WebClip }
                    .filter { $0.url.hasPrefix(WebClipsPlugin.shortcutsScheme) }
                if !shortcutClips.isEmpty {
                    let missing = shortcutClips.filter { $0.shortcutFound != true }.count
                    var note = "note: \(shortcutClips.count) web clip(s) run a Shortcut by name only — a shortcut's ID isn't stable across an unsigned reinstall, so iosbk drops it and relies on the name matching."
                    if missing > 0 {
                        note += " \(missing) of them have no matching shortcut in this backup (the shortcut was likely deleted, renamed, or never synced to this device) — see the `profile.yml` webclips section for which. Sign into the same iCloud account with Shortcuts sync enabled to get those shortcuts back. The rest can be recovered with `iosbk shortcuts export`."
                    }
                    FileHandle.standardError.write((note + "\n").data(using: .utf8)!)
                }
            }
        }

        let data = CuratedProfile.encode(sections: sections)
        if printOnly {
            print(String(data: data, encoding: .utf8) ?? "")
            return
        }

        try data.write(to: URL(fileURLWithPath: output))
        print("Wrote \(total) item(s) across \(sections.count) plugin(s) to \(output)")
        print("Edit \(output) — set keep: false for items you don't want — then run: iosbk profile install \(output)")
    }

    /// Groups web clips into actual web pages first, then Shortcuts-backed
    /// clips (`shortcuts://...` URLs) — the two are functionally different
    /// (a webpage bookmark vs. a Shortcuts automation shortcut), so grouping
    /// them makes the curated file easier to scan. Within each group, the
    /// original order from `WebClipsPlugin.extract` (alphabetical by bundle)
    /// is preserved.
    private static func webClipsWebFirst(_ items: [Any]) -> [Any] {
        let clips = items.compactMap { $0 as? WebClip }
        guard clips.count == items.count else { return items } // not WebClips; leave untouched
        let web = clips.filter { !$0.url.hasPrefix(WebClipsPlugin.shortcutsScheme) }
        let shortcuts = clips.filter { $0.url.hasPrefix(WebClipsPlugin.shortcutsScheme) }
        return (web + shortcuts).map { $0 as Any }
    }
}

struct ProfileInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Build a .mobileconfig from a curated profile.yml + the backup, then install it",
        discussion: """
        Re-reads the backup for the actual payload data (icons, keychain \
        passwords, certificate bytes, ...) and includes only the items \
        still marked keep: true in the curated file — plugins with no \
        section in the file are skipped entirely. Run `iosbk profile` (no \
        arguments) for the plugin list.
        """)

    @Argument(help: "Curated file from `iosbk profile curate`")
    var path: String = "profile.yml"

    @OptionGroup var options: BackupOptions

    @Option(name: .customLong("name"), help: "PayloadDisplayName for the merged profile")
    var displayName: String = "iosbk restore"

    @Flag(name: .customLong("no-passwords"), help: "Omit cleartext mail/VPN/Wi-Fi passwords that would otherwise be recovered from the backup keychain (encrypted backups only)")
    var noPasswords: Bool = false

    @Option(name: .shortAndLong, help: "Output .mobileconfig path")
    var output: String = "profile.mobileconfig"

    @Flag(name: .customLong("run"), help: "Actually execute the install command instead of just printing it")
    var shouldRun: Bool = false

    func run() throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("No such file: \(path)")
        }
        let sections = try CuratedProfile.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        guard !sections.isEmpty else {
            throw ValidationError("\(path) has no plugin sections; nothing to install")
        }

        if !noPasswords, sections.keys.contains(where: { $0 == "wifi" || $0 == AccountsPlugin().key }) {
            FileHandle.standardError.write(
                "warning: \(output) may contain cleartext passwords/secrets recovered from the backup keychain; store/transmit it securely and delete it after installing, or pass --no-passwords to omit them.\n"
                    .data(using: .utf8)!)
        }

        let backup = try options.resolveBackup()
        var payloads: [Payload] = []

        for key in sections.keys.sorted() {
            guard let plugin = Registry[key], plugin.buildsProfile else {
                throw ValidationError("Unknown plugin key in \(path): \(key). Available: \(ProfileCommand.profilePlugins.map(\.key).joined(separator: ", "))")
            }
            guard let kept = CuratedProfile.keptDescriptions(for: key, in: sections), !kept.isEmpty else { continue }

            // The accounts plugin can enrich its payloads with keychain
            // passwords; every other plugin ignores --no-passwords.
            if !noPasswords, key == AccountsPlugin().key {
                let accounts = AccountsPlugin()
                let entries = try accounts.extract(backup, dryRun: options.dryRun)
                let enriched = accounts.withKeychainPasswords(entries, backup: backup)
                let selected = zip(entries, enriched)
                    .filter { kept.contains(accounts.describe($0.0)) }
                    .map(\.1)
                payloads.append(contentsOf: accounts.payloads(selected))
            } else {
                let items = try plugin.extract(backup, dryRun: options.dryRun)
                let selected = items.filter { kept.contains(plugin.describe($0)) }
                payloads.append(contentsOf: plugin.payloads(selected))
            }
        }

        guard !payloads.isEmpty else {
            throw ValidationError("No payloads produced from \(path): every item may be marked keep: false, or the plugin(s) found nothing in this backup")
        }

        let data = try ProfileBuilder.build(payloads, displayName: displayName)
        try data.write(to: URL(fileURLWithPath: output))
        print("Built \(payloads.count) payload(s) into \(output)")
        try CommandRunner.emit(["cfgutil install-profile \"\(output)\""], run: shouldRun)
    }
}

