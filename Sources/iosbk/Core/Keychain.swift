import Foundation

/// Extracts secrets from a decrypted `keychain-backup.plist`.
///
/// The plist is a dictionary of item classes — `genp` (generic passwords),
/// `inet` (internet passwords), `cert`, `keys` — each an array of item
/// dictionaries. An item's attributes (service, account, …) are stored in
/// the clear; its secret value is the encrypted `v_Data` blob, decrypted per
/// item with `BackupDecryptor.decryptKeychainBlob`.
///
/// // VERIFY: confirm the attribute conventions (`svce == "AirPort"` for
/// Wi-Fi; `srvr`/`acct`/`ptcl` for mail; VPN service/label naming) against a
/// real backup and record findings in the PR under "Verified on-device".
enum Keychain {
    /// Recovers `SSID -> Wi-Fi password`. Wi-Fi keys are generic-password
    /// (`genp`) items whose service (`svce`) is "AirPort"; the account
    /// (`acct`) holds the SSID and the decrypted `v_Data` holds the password.
    static func wifiPasswords(plist: [String: Any], decryptor: BackupDecryptor) -> [String: String] {
        guard let genp = plist["genp"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for item in genp {
            guard string(item["svce"]) == "AirPort",
                  let ssid = string(item["acct"]), !ssid.isEmpty,
                  let blob = item["v_Data"] as? Data,
                  let plain = decryptor.decryptKeychainBlob(blob),
                  let password = String(data: plain, encoding: .utf8), !password.isEmpty
            else { continue }
            out[ssid] = password
        }
        return out
    }

    /// A decrypted keychain password item with the clear attributes needed to
    /// match it back to an account (mail server/username, VPN name, …).
    struct Secret {
        let itemClass: String       // "genp" | "inet"
        let account: String?        // acct
        let server: String?         // srvr
        let service: String?        // svce
        let protocolType: String?   // ptcl (e.g. imap, smtp, pop3)
        let label: String?          // labl
        let password: String        // decrypted v_Data, decoded as UTF-8
    }

    /// Decrypts every UTF-8-decodable `genp`/`inet` password item. Non-Wi-Fi
    /// callers (mail, VPN) match against the returned attributes.
    static func secrets(plist: [String: Any], decryptor: BackupDecryptor) -> [Secret] {
        var out: [Secret] = []
        for cls in ["genp", "inet"] {
            guard let items = plist[cls] as? [[String: Any]] else { continue }
            for item in items {
                guard let blob = item["v_Data"] as? Data,
                      let plain = decryptor.decryptKeychainBlob(blob),
                      let password = String(data: plain, encoding: .utf8), !password.isEmpty
                else { continue }
                out.append(Secret(
                    itemClass: cls,
                    account: string(item["acct"]),
                    server: string(item["srvr"]),
                    service: string(item["svce"]),
                    protocolType: string(item["ptcl"]),
                    label: string(item["labl"]),
                    password: password))
            }
        }
        return out
    }

    /// Incoming/outgoing mail passwords for an account, matched by server host
    /// and/or username. Prefers protocol-specific items (imap/pop → incoming,
    /// smtp → outgoing); falls back to a single matching item for both.
    static func mailPasswords(
        host: String?, username: String?, in secrets: [Secret]
    ) -> (incoming: String?, outgoing: String?) {
        let host = host?.lowercased()
        let username = username?.lowercased()
        let matches = secrets.filter { s in
            let matchesHost = host != nil && s.server?.lowercased() == host
            let matchesUser = username != nil && s.account?.lowercased() == username
            return matchesHost || matchesUser
        }
        guard !matches.isEmpty else { return (nil, nil) }

        func password(forProtocols protocols: Set<String>) -> String? {
            matches.first { protocols.contains(($0.protocolType ?? "").lowercased()) }?.password
        }
        let incoming = password(forProtocols: ["imap", "imaps", "pop3", "pop", "pops"])
        let outgoing = password(forProtocols: ["smtp", "smtps"])
        // If protocol tags are absent, use the first match for both fields.
        let fallback = matches.first?.password
        return (incoming ?? fallback, outgoing ?? incoming ?? fallback)
    }

    /// Best-effort VPN password + shared secret for an account, matched by
    /// username or by the account label/description appearing in the item's
    /// service/label. Shared secret is matched heuristically by "shared"/
    /// "ipsec"/"racoon"/"xauth" appearing in the item's service or label.
    static func vpnSecrets(
        username: String?, description: String, in secrets: [Secret]
    ) -> (password: String?, sharedSecret: String?) {
        let username = username?.lowercased()
        let desc = description.lowercased()
        func mentions(_ s: Secret) -> Bool {
            let hay = [(s.service ?? ""), (s.label ?? ""), (s.account ?? "")].joined(separator: " ").lowercased()
            return (username != nil && s.account?.lowercased() == username)
                || (!desc.isEmpty && hay.contains(desc))
        }
        let candidates = secrets.filter(mentions)
        func isSharedSecret(_ s: Secret) -> Bool {
            let hay = [(s.service ?? ""), (s.label ?? "")].joined(separator: " ").lowercased()
            return ["shared", "ipsec", "racoon", "xauth"].contains { hay.contains($0) }
        }
        let shared = candidates.first(where: isSharedSecret)?.password
        let password = candidates.first { !isSharedSecret($0) }?.password
        return (password, shared)
    }

    /// A certificate recovered from the backup keychain (`cert` items).
    struct Certificate: Encodable, Sendable {
        let label: String
        /// DER-encoded X.509 certificate bytes.
        let der: Data
    }

    /// Decrypts every `cert` keychain item into its DER certificate bytes.
    /// Like password items, a `cert` item's `v_Data` is a version-0 keychain
    /// blob; decrypted it yields the raw DER certificate.
    ///
    /// // VERIFY: confirm `cert` items store the DER certificate in `v_Data`
    /// and that `labl` (falling back to `acct`) holds a usable display name.
    static func certificates(plist: [String: Any], decryptor: BackupDecryptor) -> [Certificate] {
        guard let items = plist["cert"] as? [[String: Any]] else { return [] }
        var out: [Certificate] = []
        for (index, item) in items.enumerated() {
            guard let blob = item["v_Data"] as? Data,
                  let der = decryptor.decryptKeychainBlob(blob), !der.isEmpty
            else { continue }
            let label = string(item["labl"]) ?? string(item["acct"]) ?? "certificate-\(index + 1)"
            out.append(Certificate(label: label, der: der))
        }
        return out
    }

    /// A keychain attribute may be stored as a `String` or as raw UTF-8 `Data`.
    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let d = value as? Data { return String(data: d, encoding: .utf8) }
        return nil
    }
}
