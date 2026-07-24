import Foundation
import ArgumentParser

/// Shared `--backup` / `--dry-run` options for every subcommand that reads
/// from a backup.
struct BackupOptions: ParsableArguments {
    @Option(name: .customLong("backup"), help: "Backup directory to read (default: newest under ~/Library/Application Support/MobileSync/Backup, or $IOSBK_BACKUP).")
    var backup: String?

    @Flag(name: .customLong("dry-run"), help: "Log every resolved file/path used during extraction to stderr.")
    var dryRun: Bool = false

    func resolveBackup() throws -> Backup {
        if let backup {
            return try Backup(dir: URL(fileURLWithPath: backup))
        }
        if let envPath = ProcessInfo.processInfo.environment["IOSBK_BACKUP"], !envPath.isEmpty {
            return try Backup(dir: URL(fileURLWithPath: envPath))
        }
        return try Backup.newest()
    }
}

/// Runs (or just prints) shell commands produced by a restore strategy.
/// Real execution is gated behind `--run` everywhere in iosbk, is excluded
/// from the default unit test suite, and is only ever invoked explicitly by
/// the user.
enum CommandRunner {
    @discardableResult
    static func run(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Prints each command, running it too when `run` is true.
    static func emit(_ commands: [String], run: Bool) throws {
        for command in commands {
            print(command)
            if run {
                let status = try self.run(command)
                if status != 0 {
                    FileHandle.standardError.write("  (exited with status \(status))\n".data(using: .utf8)!)
                }
            }
        }
    }
}
