import Foundation

/// A known Wi-Fi network extracted from the backup. v1 carries no password
/// (keychain decryption is out of scope until v2) — only enough to
/// pre-stage the network so it shows up in Settings before the password
/// arrives via iCloud Keychain sign-in.
struct WifiNetwork: Encodable {
    let ssid: String
    let encryption: String // None | WEP | WPA | Any
    let hidden: Bool
    /// Wi-Fi password recovered from the backup keychain, when available.
    var password: String? = nil
}

/// Extracts known Wi-Fi networks.
///
/// The on-disk path/format is iOS-version dependent and not documented by
/// Apple. On iOS 16+ known networks live in
/// `SystemPreferencesDomain/com.apple.wifi.known-networks.plist`; older
/// locations under `SystemConfiguration/` are kept as fallbacks. The real
/// network data is only present in encrypted backups.
struct WifiPlugin: ExtractorPlugin {
    let key = "wifi"
    let summary = "Known Wi-Fi networks (with password, when recovered from an encrypted backup)"

    /// Candidate `(domain, relativePath)` pairs, most-recent-iOS-first.
    static let candidatePaths: [(domain: String, rel: String)] = [
        ("SystemPreferencesDomain", "com.apple.wifi.known-networks.plist"),
        ("SystemPreferencesDomain", "SystemConfiguration/com.apple.wifi.known-networks.plist"),
        ("SystemPreferencesDomain", "SystemConfiguration/com.apple.wifi.plist"),
        ("SystemPreferencesDomain", "SystemConfiguration/com.apple.wifi-networks.plist"),
    ]

    func extract(_ backup: Backup, dryRun: Bool) throws -> [WifiNetwork] {
        for candidate in Self.candidatePaths {
            let matches = try backup.files(domain: candidate.domain, pathLike: candidate.rel)
            guard let file = matches.first else { continue }
            guard let plist = try? backup.readPlist(file), !plist.isEmpty else { continue }

            let nets = Self.parseNetworks(plist)
            if nets.isEmpty { continue }

            // Enrich with passwords from the keychain (encrypted backups only;
            // empty otherwise, leaving each network pre-staged without a secret).
            let passwords = backup.keychainWifiPasswords()
            guard !passwords.isEmpty else { return nets }
            return nets.map { net in
                var enriched = net
                enriched.password = passwords[net.ssid]
                return enriched
            }
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
                HIDDEN_NETWORK: net.hidden,
                Password: net.password))
        }
    }

    /// Parses the modern (iOS 16+) `com.apple.wifi.known-networks.plist`,
    /// a dictionary keyed by `wifi.network.ssid.<SSID>` (and
    /// `wifi.network.passpoint.<domain>`) whose values are per-network dicts.
    /// Older shapes — a `List` array of network dicts (optionally wrapped in a
    /// `NetworkProfile` dict) and flat SSID-keyed dicts — are handled too.
    static func parseNetworks(_ plist: [String: Any]) -> [WifiNetwork] {
        var out: [WifiNetwork] = []

        if let list = plist["List"] as? [[String: Any]] {
            for entry in list {
                // iOS 13+: network data lives inside a nested "NetworkProfile" dict.
                let inner = (entry["NetworkProfile"] as? [String: Any]) ?? entry
                if let net = network(from: inner) { out.append(net) }
            }
        }

        for (key, value) in plist where key != "List" {
            if let entry = value as? [String: Any] {
                if let net = network(from: entry, fallbackSSID: ssid(fromKey: key)) {
                    out.append(net)
                }
            }
        }

        return out.sorted { $0.ssid < $1.ssid }
    }

    private static func network(from entry: [String: Any], fallbackSSID: String? = nil) -> WifiNetwork? {
        // Prefer the authoritative SSID bytes; fall back to the string form,
        // then to the SSID parsed from the dictionary key.
        let ssid = decodeSSID(entry["SSID"]) ?? (entry["SSID_STR"] as? String) ?? fallbackSSID
        guard let ssid, !ssid.isEmpty else { return nil }
        let encryption = encryptionType(entry)
        let hidden = (entry["HIDDEN_NETWORK"] as? Bool) ?? (entry["Hidden"] as? Bool) ?? false
        return WifiNetwork(ssid: ssid, encryption: encryption, hidden: hidden)
    }

    /// Strips the `wifi.network.ssid.` / `wifi.network.passpoint.` prefix from
    /// a known-networks dictionary key to recover the SSID.
    private static func ssid(fromKey key: String) -> String {
        for prefix in ["wifi.network.ssid.", "wifi.network.passpoint."] where key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return key
    }

    /// Decodes the `SSID` value, which is raw bytes (`Data`) in modern backups.
    private static func decodeSSID(_ value: Any?) -> String? {
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        if let str = value as? String, !str.isEmpty { return str }
        return nil
    }

    /// Maps iOS security descriptors to the payload's encryption vocabulary.
    /// An explicit `EncryptionType` (older shapes) is already a valid payload
    /// token and is passed through verbatim. The modern known-networks format
    /// instead carries `SupportedSecurityTypes` like "WPA2 Personal", which is
    /// normalised to the matching token (None | WEP | WPA | WPA2 | WPA3 | Any).
    private static func encryptionType(_ entry: [String: Any]) -> String {
        if let explicit = entry["EncryptionType"] as? String, !explicit.isEmpty {
            return explicit
        }
        let raw = (entry["SupportedSecurityTypes"] as? String)
            ?? (entry["SecurityType"] as? String)
        guard let raw else { return "Any" }
        let lower = raw.lowercased()
        if lower.contains("wpa3") { return "WPA3" }
        if lower.contains("wpa2") { return "WPA2" }
        if lower.contains("wpa") { return "WPA" }
        if lower.contains("wep") { return "WEP" }
        if lower.contains("none") || lower.contains("open") { return "None" }
        return "Any"
    }
}
