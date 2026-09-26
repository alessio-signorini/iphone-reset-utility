import Foundation

/// A single home-screen web clip extracted from `HomeDomain`.
struct WebClip: Encodable {
    let bundle: String // e.g. "example.com.webclip"
    let title: String
    let url: String
    let fullScreen: Bool
    let icon: Data?
    /// For `shortcuts://` clips: whether a shortcut with the target `name`
    /// was also recovered from this backup (see `ShortcutsExport`). `nil`
    /// for ordinary web clips.
    var shortcutFound: Bool? = nil
}

/// Extracts home-screen web clips (`HomeDomain/Library/WebClips/*.webclip`).
struct WebClipsPlugin: ExtractorPlugin {
    let key = "webclips"
    let summary = "Home-screen web clips"

    /// URL scheme used by web clips that "Add to Home Screen" creates from
    /// inside the Shortcuts app (as opposed to an actual webpage).
    static let shortcutsScheme = "shortcuts://"

    private static let bundleRegex = try! NSRegularExpression(
        pattern: #"^Library/WebClips/([^/]+\.webclip)/(.+)$"#)

    func extract(_ backup: Backup, dryRun: Bool) throws -> [WebClip] {
        let files = try backup.files(domain: "HomeDomain", pathLike: "Library/WebClips/%")

        // Group leaf files by their ".webclip" bundle directory.
        var byBundle: [String: [String: BackupFile]] = [:]
        for f in files {
            guard let (bundle, leaf) = matchBundle(f.rel) else { continue }
            byBundle[bundle, default: [:]][leaf] = f
        }

        if dryRun {
            FileHandle.standardError.write(
                "webclips: found \(byBundle.count) candidate bundle(s)\n".data(using: .utf8)!)
        }

        let availableShortcuts = Set(ShortcutsExport.availableNames(in: backup).map { $0.lowercased() })
        var clips: [WebClip] = []
        for (bundle, leaves) in byBundle.sorted(by: { $0.key < $1.key }) {
            guard let infoFile = leaves["Info.plist"] else { continue }
            let info: [String: Any]
            do {
                info = try backup.readPlist(infoFile)
            } catch {
                if dryRun {
                    FileHandle.standardError.write(
                        "webclips: readPlist(\(bundle)/Info.plist) failed: \(error)\n".data(using: .utf8)!)
                }
                continue
            }
            guard let rawURL = info["URL"] as? String else { continue } // skip if no URL
            let url = Self.stripUnstableShortcutID(from: rawURL)

            let title = (info["Title"] as? String) ?? bundle.replacingOccurrences(of: ".webclip", with: "")
            let fullScreen = (info["FullScreen"] as? Bool) ?? false

            var icon: Data?
            if let iconFile = leaves["icon.png"] {
                icon = try? backup.readData(iconFile)
            } else if let firstPNG = leaves.keys.filter({ $0.hasSuffix(".png") }).sorted().first {
                icon = try? backup.readData(leaves[firstPNG]!)
            }

            var shortcutFound: Bool?
            if let shortcutName = Self.shortcutName(from: url) {
                shortcutFound = availableShortcuts.contains(shortcutName.lowercased())
            }

            clips.append(WebClip(
                bundle: bundle, title: title, url: url, fullScreen: fullScreen, icon: icon,
                shortcutFound: shortcutFound))
        }
        return clips
    }

    func describe(_ item: WebClip) -> String {
        let suffix = item.icon == nil ? " (no icon)" : ""
        if let shortcutName = Self.shortcutName(from: item.url) {
            let status = item.shortcutFound == true
                ? "found in this backup — recover it with `iosbk shortcuts export`, then re-add it with the same name"
                : "not found in this backup (the shortcut it runs may have been deleted, renamed, or never synced to this device; sign into the same iCloud account with Shortcuts sync enabled to restore it)"
            return "\(item.title) -> \(item.url)\(suffix) [runs Shortcut \"\(shortcutName)\" by name — \(status)]"
        }
        return "\(item.title) -> \(item.url)\(suffix)"
    }

    func payloads(_ items: [WebClip]) -> [Payload] {
        items.map { clip in
            let identity = PayloadIdentity.make(prefix: "com.local.iosbk.webclip")
            return .webClip(WebClipPayload(
                PayloadIdentifier: identity.identifier,
                PayloadUUID: identity.uuid,
                PayloadDisplayName: clip.title,
                URL: clip.url,
                Label: clip.title,
                FullScreen: clip.fullScreen,
                Icon: clip.icon))
        }
    }

    private func matchBundle(_ rel: String) -> (bundle: String, leaf: String)? {
        let range = NSRange(rel.startIndex..<rel.endIndex, in: rel)
        guard let match = Self.bundleRegex.firstMatch(in: rel, range: range),
              let bundleRange = Range(match.range(at: 1), in: rel),
              let leafRange = Range(match.range(at: 2), in: rel)
        else { return nil }
        return (String(rel[bundleRange]), String(rel[leafRange]))
    }

    /// Home-screen web clips created from within the Shortcuts app link back
    /// to a specific Shortcut via
    /// `shortcuts://x-callback-url/run-shortcut?name=...&id=<UUID>`. That
    /// `id` is the shortcut's *local* identifier and does not survive a
    /// reinstall — re-adding a `.shortcut` file (or accepting "Allow
    /// Untrusted Shortcuts") always assigns a brand-new UUID, even to an
    /// otherwise identical shortcut, so a restored web clip carrying the old
    /// `id` would silently fail to run anything. The `run-shortcut` action
    /// can also be invoked by `name` alone, which *does* survive a reinstall
    /// as long as the recreated shortcut keeps the same name — so the `id`
    /// query parameter is dropped here, keeping only `name` (and any other
    /// harmless params).
    static func stripUnstableShortcutID(from url: String) -> String {
        guard url.hasPrefix(shortcutsScheme), var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.filter { $0.name != "id" }
        return components.string ?? url
    }

    /// The shortcut's `name` query parameter, URL-decoded, or `nil` if
    /// `url` isn't a `shortcuts://` link.
    static func shortcutName(from url: String) -> String? {
        guard url.hasPrefix(shortcutsScheme), let components = URLComponents(string: url) else { return nil }
        return components.queryItems?.first { $0.name == "name" }?.value
    }
}
