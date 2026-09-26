import Foundation
import ArgumentParser

@main
struct Iosbk: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iosbk",
        abstract: "Selective extract + restore from an unencrypted iOS backup",
        discussion: """
        Reads a real, unencrypted backup from \
        ~/Library/Application Support/MobileSync/Backup, lets you pick which \
        assets to bring back (apps, web clips, Wi-Fi networks, accounts), \
        and generates individually-installable restore artifacts instead of \
        an all-or-nothing device restore.
        """,
        version: "1.0.0",
        subcommands: [
            BackupsCommand.self,
            ListCommand.self,
        ],
        groupedSubcommands: [
            CommandGroup(name: "Curate", subcommands: [
                AppsCommand.self,
                ProfileCommand.self,
            ]),
            CommandGroup(name: "Export (restorable)", subcommands: [
                WalletCommand.self,
                PhotosCommand.self,
                ContactsCommand.self,
                CalendarCommand.self,
                ShortcutsCommand.self,
            ]),
            CommandGroup(name: "Dump (archival only)", subcommands: [
                NotesCommand.self,
                MessagesCommand.self,
                HealthCommand.self,
                CallsCommand.self,
                VoicemailCommand.self,
                BluetoothCommand.self,
                RemindersCommand.self,
                BookmarksCommand.self,
            ]),
        ])

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let helpText = groupHelpForStrayOption(arguments) {
            print(dropHelpSubcommandNotice(helpText))
            return
        }
        do {
            let command = try await asyncParseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                var command = command
                try command.run()
            }
        } catch {
            let text = dropHelpSubcommandNotice(Self.fullMessage(for: error, columns: nil))
            let exitCode = Self.exitCode(for: error)
            if !text.isEmpty {
                if exitCode == .success {
                    print(text)
                } else {
                    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
                }
            }
            Foundation.exit(exitCode.rawValue)
        }
    }

    /// ArgumentParser appends a "See 'iosbk help <command> <subcommand>' for
    /// detailed help." line to any help screen that lists subcommands, but
    /// iosbk doesn't have a `help` command, so strip it out.
    private static func dropHelpSubcommandNotice(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("for detailed help.") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// Walks `arguments` down the static subcommand tree as far as it
    /// matches known subcommand names. If it stops at a "group" command
    /// (one that only routes to subcommands, like `iosbk shortcuts`) because
    /// the next token looks like an option rather than a subcommand name,
    /// ArgumentParser would otherwise report an unfriendly "Unknown option"
    /// error. That option is almost always a *global* one meant for a leaf
    /// subcommand (e.g. `--password`), so treat this the same as invoking
    /// the group with no arguments at all: just show its help.
    private static func groupHelpForStrayOption(_ arguments: [String]) -> String? {
        var node: ParsableCommand.Type = Self.self
        var remaining = arguments[...]
        while let token = remaining.first, !token.hasPrefix("-"), token != "help" {
            guard let match = node.configuration.subcommands.first(where: { $0._commandName == token }) else {
                break
            }
            node = match
            remaining = remaining.dropFirst()
        }
        guard let next = remaining.first, next.hasPrefix("-"), next != "-h", next != "--help" else {
            return nil
        }
        guard !node.configuration.subcommands.isEmpty else { return nil }
        return node == Self.self
            ? Self.helpMessage()
            : Self.helpMessage(for: node)
    }
}
