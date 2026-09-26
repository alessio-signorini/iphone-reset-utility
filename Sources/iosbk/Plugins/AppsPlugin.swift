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
    // Restores via its own curate/download/install workflow (`iosbk apps`),
    // not via `iosbk profile`.
    let buildsProfile = false

    func extract(_ backup: Backup, dryRun: Bool) throws -> [String] {
        let files = try backup.files(includeDirs: true)
        let bundleIDs = files
            .map(\.domain)
            .filter { $0.hasPrefix("AppDomain-") }
            .map { String($0.dropFirst("AppDomain-".count)) }
            // com.apple.* entries are built-in/system apps and services that
            // reinstall automatically with iOS itself — not something the
            // App Store can (re)install, so they're noise in a restore list.
            .filter { !$0.hasPrefix("com.apple.") }
        let unique = Set(bundleIDs)
        if dryRun {
            FileHandle.standardError.write(
                "apps: found \(unique.count) AppDomain-* entries (excluding com.apple.*)\n".data(using: .utf8)!)
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
        case html
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
            case .html:
                preconditionFailure("html strategy must be handled by the caller before invoking restoreCommands")
            }
        }
        return (commands, warnings)
    }

    /// Generates a self-contained, mobile-friendly HTML page with an
    /// `itms-apps://` link for every kept, enriched app.
    ///
    /// The page is intended to be AirDropped to the iPhone and opened in
    /// Safari, where each button opens the App Store page for that app.
    /// Apps that are missing a `storeID` (not yet enriched) are listed
    /// separately as a reminder to run `curate apps --enrich` first.
    static func htmlPage(apps: [CuratedApp]) -> String {
        let kept = apps.filter(\.keep)
        let enriched = kept.filter { $0.storeID != nil }
        let missing  = kept.filter { $0.storeID == nil }

        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>App Store Install List</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, sans-serif; }
            body  { margin: 0; padding: 16px; background: #f2f2f7; }
            h1    { font-size: 22px; margin: 0 0 4px; }
            p.sub { color: #8e8e93; margin: 0 0 20px; font-size: 14px; }
            ul    { list-style: none; padding: 0; margin: 0 0 28px; }
            li    { margin-bottom: 10px; }
            a.btn {
              display: block; padding: 14px 16px;
              background: #fff; border-radius: 12px;
              text-decoration: none; color: #1c1c1e;
              font-size: 16px; font-weight: 500;
              box-shadow: 0 1px 3px rgba(0,0,0,.12);
            }
            a.btn span.badge {
              float: right; font-size: 14px; font-weight: 600;
              color: #007aff;
            }
            h2 { font-size: 15px; color: #8e8e93; text-transform: uppercase;
                 letter-spacing: .04em; margin: 0 0 8px; }
            .warn { color: #ff9500; }
            @media (prefers-color-scheme: dark) {
              body  { background: #1c1c1e; }
              a.btn { background: #2c2c2e; color: #f2f2f7;
                      box-shadow: none; }
            }
          </style>
        </head>
        <body>
          <h1>App Store Install List</h1>
          <p class="sub">\(enriched.count) app\(enriched.count == 1 ? "" : "s") — tap each to open the App Store</p>
        """

        if !enriched.isEmpty {
            html += "  <ul>\n"
            for app in enriched {
                let label = app.name ?? app.bundleID
                let url   = "itms-apps://itunes.apple.com/app/id\(app.storeID!)"
                html += "    <li><a class=\"btn\" href=\"\(url)\">\(escapeHTML(label))<span class=\"badge\">GET</span></a></li>\n"
            }
            html += "  </ul>\n"
        }

        if !missing.isEmpty {
            html += "  <h2 class=\"warn\">Missing Store ID — run <code>iosbk apps curate --enrich</code></h2>\n  <ul>\n"
            for app in missing {
                let label = app.name ?? app.bundleID
                html += "    <li><a class=\"btn\" href=\"#\">\(escapeHTML(label))</a></li>\n"
            }
            html += "  </ul>\n"
        }

        html += "</body>\n</html>\n"
        return html
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Warnings for the download flow: hints for kept apps with no display
    /// name, so the user can verify the bundle ID is correct before downloading.
    static func downloadWarnings(apps: [CuratedApp]) -> [String] {
        apps.filter(\.keep).compactMap { app in
            guard app.name == nil else { return nil }
            return "\(app.bundleID) has no display name — run `iosbk apps curate --enrich` to verify the bundle ID before downloading"
        }
    }
}
