import Foundation
import Testing
@testable import iosbk

/// Runs the built `iosbk` binary as a subprocess and captures stdout/stderr.
enum CLI {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = try binaryURL()
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Locates the freshly-built `iosbk` executable in `.build/**/<config>/iosbk`
    /// relative to the package root (derived from this file's own path,
    /// since `swift test`'s runner location varies by toolchain/config and
    /// isn't reliably discoverable via `Bundle`).
    private static func binaryURL() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // iosbkTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let buildDir = repoRoot.appending(path: ".build")
        let fm = FileManager.default

        for config in ["debug", "release"] {
            let direct = buildDir.appending(path: config).appending(path: "iosbk")
            if fm.isExecutableFile(atPath: direct.path) { return direct }
        }

        if let archDirs = try? fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: nil) {
            for archDir in archDirs {
                for config in ["debug", "release"] {
                    let candidate = archDir.appending(path: config).appending(path: "iosbk")
                    if fm.isExecutableFile(atPath: candidate.path) { return candidate }
                }
            }
        }

        throw NSError(domain: "CLI", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "couldn't locate built iosbk binary under \(buildDir.path)",
        ])
    }
}
