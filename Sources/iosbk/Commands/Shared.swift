import Foundation
import ArgumentParser

/// Shared `--backup` / `--password` / `--dry-run` options for every subcommand
/// that reads from a backup.
struct BackupOptions: ParsableArguments {
    @Option(name: .customLong("backup"), help: "Backup directory to read (default: newest under ~/Library/Application Support/MobileSync/Backup, or $IOSBK_BACKUP)")
    var backup: String?

    @Option(name: .customLong("password"), help: "Password for encrypted backups (or $IOSBK_PASSWORD)")
    var password: String?

    @Flag(name: .customLong("dry-run"), help: "Log every resolved file/path used during extraction to stderr")
    var dryRun: Bool = false

    func resolveBackup() throws -> Backup {
        let dir: URL
        if let path = backup {
            dir = URL(fileURLWithPath: path)
        } else if let env = ProcessInfo.processInfo.environment["IOSBK_BACKUP"], !env.isEmpty {
            dir = URL(fileURLWithPath: env)
        } else {
            dir = try Backup.newestDir()
        }

        let pw = password ?? ProcessInfo.processInfo.environment["IOSBK_PASSWORD"]
        if let pw {
            return try Backup(dir: dir, password: pw)
        }
        return try Backup(dir: dir)
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
