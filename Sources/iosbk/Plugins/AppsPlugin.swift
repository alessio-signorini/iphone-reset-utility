import Foundation

/// Extracts installed third-party app bundle IDs and produces
/// `cfgutil`/App Store restore commands.
///
/// Modern (iOS 10+) unencrypted backups contain no `.ipa` payload or
/// `iTunesMetadata.plist` for third-party apps — only an `AppDomain-<bundleID>`
/// domain marks that the app was installed. That means the bundle ID is all
/// that's reliably recoverable; anything else (display name, App Store id)
/// is best-effort enrichment via the iTunes Lookup API.
struct AppsPlugin: ExtractorPlugin {
    let key = "apps"
    let summary = "Installed third-party apps (bundle IDs)"

    func extract(_ backup: Backup, dryRun: Bool) throws -> [String] {
        let files = try backup.files(includeDirs: true)
        let bundleIDs = files
            .map(\.domain)
            .filter { $0.hasPrefix("AppDomain-") }
            .map { String($0.dropFirst("AppDomain-".count)) }
        let unique = Set(bundleIDs)
        if dryRun {
            FileHandle.standardError.write(
                "apps: found \(unique.count) AppDomain-* entries\n".data(using: .utf8)!)
        }
        return unique.sorted()
    }

    func describe(_ item: String) -> String { item }
}

// MARK: - Curated app model (apps.yml)

struct CuratedApp: Codable, Equatable {
    var bundleID: String
    var name: String?
    /// App Store numeric id, populated by `--enrich`. Persisted in
    /// `apps.yml` so `install apps --strategy appstore-open` can use it
    /// after a fresh `iosbk` invocation (the YAML round-trips this field).
    var storeID: Int?
    var keep: Bool
}

/// Result of an iTunes Lookup query, used to enrich a curated app.
struct ITunesLookupResult {
    let name: String?
    let storeID: Int?
}

/// Injectable so `--enrich` can be exercised in tests without a live
/// network call.
protocol ITunesLookupClient {
    func lookup(bundleID: String) async throws -> ITunesLookupResult?
}

/// Real implementation: `GET https://itunes.apple.com/lookup?bundleId=<id>`.
struct LiveITunesLookupClient: ITunesLookupClient {
    func lookup(bundleID: String) async throws -> ITunesLookupResult? {
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
        comps.queryItems = [URLQueryItem(name: "bundleId", value: bundleID)]
        guard let url = comps.url else { return nil }

        let (data, _) = try await URLSession.shared.data(from: url)
        struct LookupResponse: Decodable {
            struct Result: Decodable {
                let trackName: String?
                let trackId: Int?
            }
            let results: [Result]
        }
        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let first = decoded.results.first else { return nil }
        return ITunesLookupResult(name: first.trackName, storeID: first.trackId)
    }
}

extension AppsPlugin {
    /// Builds the curated-app list, optionally enriching each entry via
    /// `client` (name + App Store id). When `client` is nil, entries are
    /// emitted with `name: nil` and `keep: true`.
    static func curate(bundleIDs: [String], client: ITunesLookupClient?) async -> [CuratedApp] {
        var out: [CuratedApp] = []
        for id in bundleIDs.sorted() {
            var name: String?
            var storeID: Int?
            if let client {
                let result = try? await client.lookup(bundleID: id)
                name = result?.name
                storeID = result?.storeID
            }
            out.append(CuratedApp(bundleID: id, name: name, storeID: storeID, keep: true))
        }
        return out
    }

    enum InstallStrategy: String, CaseIterable {
        case cfgutil
        case appstoreOpen = "appstore-open"
    }

    /// Restore-command generation for a curated `apps.yml`. Only apps with
    /// `keep == true` are considered.
    ///
    /// - `cfgutil`: needs `ipaDir`, maps `bundleID -> <ipaDir>/<bundleID>.ipa`
    ///   (skips + logs apps with no matching `.ipa`); emits
    ///   `cfgutil install-app "<ipa>"`. Note `cfgutil` installs onto a clean
    ///   device and cannot update an already-installed app in place.
    /// - `appstore-open`: only for entries that were enriched with a store
    ///   id; emits `open "itms-apps://itunes.apple.com/app/id<storeID>"` so
    ///   each app's page opens in the App Store and you tap **Get**.
    static func restoreCommands(
        apps: [CuratedApp], strategy: InstallStrategy, ipaDir: URL?
    ) -> (commands: [String], warnings: [String]) {
        var commands: [String] = []
        var warnings: [String] = []
        for app in apps where app.keep {
            switch strategy {
            case .cfgutil:
                guard let ipaDir else {
                    warnings.append("--ipa-dir is required for --strategy cfgutil")
                    continue
                }
                let candidate = ipaDir.appending(path: "\(app.bundleID).ipa")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    commands.append("cfgutil install-app \"\(candidate.path)\"")
                } else {
                    warnings.append("no .ipa found for \(app.bundleID) in \(ipaDir.path); skipped")
                }
            case .appstoreOpen:
                guard let storeID = app.storeID else {
                    warnings.append("\(app.bundleID) has no App Store id; run curate --enrich first, or use --strategy cfgutil")
                    continue
                }
                commands.append("open \"itms-apps://itunes.apple.com/app/id\(storeID)\"")
            }
        }
        return (commands, warnings)
    }
}
