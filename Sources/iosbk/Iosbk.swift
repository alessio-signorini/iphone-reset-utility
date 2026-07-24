import Foundation
import ArgumentParser

@main
struct Iosbk: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iosbk",
        abstract: "Selective extract + restore from an unencrypted iOS backup.",
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
            ExtractCommand.self,
            ProfileCommand.self,
            CurateCommand.self,
            InstallCommand.self,
        ])
}
