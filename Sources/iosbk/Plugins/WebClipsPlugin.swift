import Foundation

/// A single home-screen web clip extracted from `HomeDomain`.
struct WebClip: Encodable {
    let bundle: String // e.g. "example.com.webclip"
    let title: String
    let url: String
    let fullScreen: Bool
    let icon: Data?
}

/// Extracts home-screen web clips (`HomeDomain/Library/WebClips/*.webclip`).
struct WebClipsPlugin: ExtractorPlugin {
    let key = "webclips"
    let summary = "Home-screen web clips"

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

        var clips: [WebClip] = []
        for (bundle, leaves) in byBundle.sorted(by: { $0.key < $1.key }) {
            guard let infoFile = leaves["Info.plist"] else { continue }
            guard let info = try? backup.readPlist(infoFile) else { continue }
            guard let url = info["URL"] as? String else { continue } // skip if no URL

            let title = (info["Title"] as? String) ?? bundle.replacingOccurrences(of: ".webclip", with: "")
            let fullScreen = (info["FullScreen"] as? Bool) ?? false

            var icon: Data?
            if let iconFile = leaves["icon.png"] {
                icon = try? backup.readData(iconFile)
            } else if let firstPNG = leaves.keys.filter({ $0.hasSuffix(".png") }).sorted().first {
                icon = try? backup.readData(leaves[firstPNG]!)
            }

            clips.append(WebClip(bundle: bundle, title: title, url: url, fullScreen: fullScreen, icon: icon))
        }
        return clips
    }

    func describe(_ item: WebClip) -> String {
        "\(item.title) -> \(item.url)\(item.icon == nil ? " (no icon)" : "")"
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
}
