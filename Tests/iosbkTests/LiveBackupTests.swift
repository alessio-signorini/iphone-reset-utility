import Foundation
import Testing
@testable import iosbk

/// Live suite: exercises the plugins against the newest *real* backup on
/// this Mac. Gated behind `IOSBK_LIVE=1` so `swift test` stays deterministic
/// by default (this suite's outcome depends on whatever's actually in
/// ~/Library/Application Support/MobileSync/Backup on the machine running
/// it).
///
/// Run with:
///   IOSBK_LIVE=1 swift test --filter LiveBackupTests
///
/// Findings (which wifi/accounts candidate path matched, or why not) should
/// be recorded in the PR under "Verified on-device".
@Suite("Live backup", .enabled(if: ProcessInfo.processInfo.environment["IOSBK_LIVE"] == "1"))
struct LiveBackupTests {
    @Test("Backup.newest() locates a real backup directory")
    func locatesRealBackup() throws {
        let backup = try Backup.newest()
        print("iosbk live: using backup at \(backup.dir.path)")
    }

    @Test("apps plugin extracts without throwing")
    func appsExtractsCleanly() throws {
        let backup = try Backup.newest()
        let bundleIDs = try AppsPlugin().extract(backup, dryRun: true)
        print("iosbk live: found \(bundleIDs.count) installed app(s)")
    }

    @Test("webclips plugin extracts without throwing")
    func webClipsExtractsCleanly() throws {
        let backup = try Backup.newest()
        let clips = try WebClipsPlugin().extract(backup, dryRun: true)
        print("iosbk live: found \(clips.count) web clip(s)")
    }

    @Test("wifi plugin: confirms which // VERIFY candidate path matches on this backup")
    func wifiPluginConfirmsCandidatePath() throws {
        let backup = try Backup.newest()
        let networks = try WifiPlugin().extract(backup, dryRun: true)
        print("iosbk live: found \(networks.count) known wifi network(s); see stderr above for which candidate path matched.")
    }

    @Test("accounts plugin: confirms Accounts3.sqlite schema on this backup")
    func accountsPluginConfirmsSchema() throws {
        let backup = try Backup.newest()
        let entries = try AccountsPlugin().extract(backup, dryRun: true)
        print("iosbk live: found \(entries.count) account(s); see stderr above for schema fallback notes.")
    }

    /// Only runs when a device is tethered *and* Apple Configurator's
    /// `cfgutil` is installed; otherwise it's skipped with an explanatory
    /// message rather than failing the suite.
    @Test("install profile --run against a throwaway profile (requires tethered device + cfgutil)")
    func installProfileRunAgainstTetheredDevice() throws {
        guard CommandLine.arguments.contains("--iosbk-live-install") else {
            print("iosbk live: skipping install --run (pass --iosbk-live-install to opt in)")
            return
        }
        guard let cfgutil = Self.which("cfgutil") else {
            print("iosbk live: cfgutil not found; skipping install --run")
            return
        }

        let payload = Payload.wifi(WifiPayload(
            PayloadIdentifier: "com.local.iosbk.live-test",
            PayloadUUID: UUID().uuidString,
            PayloadDisplayName: "iosbk live test (throwaway)",
            SSID_STR: "iosbk-live-test-network",
            EncryptionType: "None",
            HIDDEN_NETWORK: true))
        let data = try ProfileBuilder.build([payload], displayName: "iosbk live test (throwaway)")
        let path = FileManager.default.temporaryDirectory.appending(path: "iosbk-live-\(UUID().uuidString).mobileconfig")
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cfgutil)
        process.arguments = ["install-profile", path.path]
        try process.run()
        process.waitUntilExit()
        print("iosbk live: cfgutil install-profile exited with status \(process.terminationStatus)")
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty ?? true) ? nil : output
    }
}
