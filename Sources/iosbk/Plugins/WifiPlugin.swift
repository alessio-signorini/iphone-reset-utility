import Foundation

/// A known Wi-Fi network extracted from the backup. v1 carries no password
/// (keychain decryption is out of scope until v2) — only enough to
/// pre-stage the network so it shows up in Settings before the password
/// arrives via iCloud Keychain sign-in.
struct WifiNetwork: Encodable {
    let ssid: String
    let encryption: String // None | WEP | WPA | Any
    let hidden: Bool
}

/// Extracts known Wi-Fi networks.
///
/// // VERIFY: the on-disk path/format for known networks is iOS-version
/// dependent and not documented by Apple. This plugin probes a short list of
/// historically-observed candidates, in order, and logs (under `--dry-run`)
/// which one actually matched on the backup being read. Confirm the
/// matching path against a real backup and record it in the PR under
/// "Verified on-device".
struct WifiPlugin: ExtractorPlugin {
    let key = "wifi"
    let summary = "Known Wi-Fi networks (SSID only, no passwords)"

    /// Candidate `(domain, relativePath)` pairs, most-recent-iOS-first.
    /// // VERIFY: confirm which of these actually exists in a real backup;
    /// update ordering/add candidates once confirmed on-device.
    static let candidatePaths: [(domain: String, rel: String)] = [
        ("SystemPreferencesDomain", "SystemConfiguration/com.apple.wifi.plist"),
        ("SystemPreferencesDomain", "SystemConfiguration/com.apple.wifi.known-networks.plist"),
        ("SystemPreferencesDomain", "SystemConfiguration/com.apple.wifi-networks.plist.plist"),
    ]

    func extract(_ backup: Backup, dryRun: Bool) throws -> [WifiNetwork] {
        for candidate in Self.candidatePaths {
            let matches = try backup.files(domain: candidate.domain, pathLike: candidate.rel)
            guard let file = matches.first else { continue }

            if dryRun {
                FileHandle.standardError.write(
                    "wifi: matched \(candidate.domain)/\(candidate.rel)\n".data(using: .utf8)!)
            }

            guard let plist = try? backup.readPlist(file) else { continue }
            return Self.parseNetworks(plist)
        }

        if dryRun {
            FileHandle.standardError.write(
                "wifi: no candidate path matched; tried \(Self.candidatePaths.count) known locations\n"
                    .data(using: .utf8)!)
        }
        return []
    }

    func describe(_ item: WifiNetwork) -> String {
        "\(item.ssid) (\(item.encryption)\(item.hidden ? ", hidden" : ""))"
    }

    func payloads(_ items: [WifiNetwork]) -> [Payload] {
        items.map { net in
            let identity = PayloadIdentity.make(prefix: "com.local.iosbk.wifi")
            return .wifi(WifiPayload(
                PayloadIdentifier: identity.identifier,
                PayloadUUID: identity.uuid,
                PayloadDisplayName: net.ssid,
                SSID_STR: net.ssid,
                EncryptionType: net.encryption,
                HIDDEN_NETWORK: net.hidden))
        }
    }

    /// // VERIFY: the known-networks plist is commonly a dictionary keyed by
    /// SSID (or a "List" array of network dictionaries) depending on iOS
    /// version; this parses both shapes defensively, skipping anything that
    /// doesn't look like a network entry rather than crashing.
    static func parseNetworks(_ plist: [String: Any]) -> [WifiNetwork] {
        var out: [WifiNetwork] = []

        if let list = plist["List"] as? [[String: Any]] {
            for entry in list {
                if let net = network(from: entry) { out.append(net) }
            }
        }

        for (key, value) in plist where key != "List" {
            if let entry = value as? [String: Any] {
                if let net = network(from: entry, fallbackSSID: key) {
                    out.append(net)
                }
            }
        }

        return out.sorted { $0.ssid < $1.ssid }
    }

    private static func network(from entry: [String: Any], fallbackSSID: String? = nil) -> WifiNetwork? {
        let ssid = (entry["SSID_STR"] as? String) ?? (entry["SSID"] as? String) ?? fallbackSSID
        guard let ssid, !ssid.isEmpty else { return nil }
        let encryption = (entry["EncryptionType"] as? String) ?? inferEncryption(entry) ?? "Any"
        let hidden = (entry["HIDDEN_NETWORK"] as? Bool) ?? (entry["Hidden"] as? Bool) ?? false
        return WifiNetwork(ssid: ssid, encryption: encryption, hidden: hidden)
    }

    private static func inferEncryption(_ entry: [String: Any]) -> String? {
        if let sec = entry["SecurityType"] as? String { return sec }
        return nil
    }
}
