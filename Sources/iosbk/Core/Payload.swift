import Foundation

// MARK: - Configuration profile payload models
//
// These map 1:1 to Apple's mobileconfig payload dictionaries. Field naming
// intentionally follows Apple's own PascalCase keys (not Swift convention)
// since `Encodable`'s synthesized `CodingKeys` are derived from the stored
// property names and these are encoded directly to plist keys.

struct WebClipPayload: Encodable {
    let PayloadType = "com.apple.webClip.managed"
    let PayloadVersion = 1
    let PayloadIdentifier: String
    let PayloadUUID: String
    let PayloadDisplayName: String
    let URL: String
    let Label: String
    let IsRemovable = true
    let Precomposed = true
    let FullScreen: Bool
    let Icon: Data? // nil -> key omitted; else <data>
}

struct WifiPayload: Encodable {
    let PayloadType = "com.apple.wifi.managed"
    let PayloadVersion = 1
    let PayloadIdentifier: String
    let PayloadUUID: String
    let PayloadDisplayName: String
    let SSID_STR: String
    let EncryptionType: String // None | WEP | WPA | Any
    let HIDDEN_NETWORK: Bool
    // NOTE: no Password key in v1 (keychain out of scope).
}

struct MailPayload: Encodable {
    let PayloadType = "com.apple.mail.managed"
    let PayloadVersion = 1
    let PayloadIdentifier: String
    let PayloadUUID: String
    let PayloadDisplayName: String
    let EmailAccountDescription: String
    let EmailAccountName: String
    let EmailAddress: String?
    let IncomingMailServerHostName: String?
    let IncomingMailServerUsername: String?
    let OutgoingMailServerHostName: String?
    let OutgoingMailServerUsername: String?
}

struct CalDAVPayload: Encodable {
    let PayloadType = "com.apple.caldav.account"
    let PayloadVersion = 1
    let PayloadIdentifier: String
    let PayloadUUID: String
    let PayloadDisplayName: String
    let CalDAVAccountDescription: String
    let CalDAVHostName: String
    let CalDAVUsername: String?
}

struct CardDAVPayload: Encodable {
    let PayloadType = "com.apple.carddav.account"
    let PayloadVersion = 1
    let PayloadIdentifier: String
    let PayloadUUID: String
    let PayloadDisplayName: String
    let CardDAVAccountDescription: String
    let CardDAVHostName: String
    let CardDAVUsername: String?
}

struct VPNPayload: Encodable {
    let PayloadType = "com.apple.vpn.managed"
    let PayloadVersion = 1
    let PayloadIdentifier: String
    let PayloadUUID: String
    let PayloadDisplayName: String
    let UserDefinedName: String
    let VPNSubType: String?
    let VPNUsername: String?
    let VPNServer: String?
}

/// Type-erased array element so one profile can carry mixed payload types.
enum Payload: Encodable {
    case webClip(WebClipPayload)
    case wifi(WifiPayload)
    case mail(MailPayload)
    case caldav(CalDAVPayload)
    case carddav(CardDAVPayload)
    case vpn(VPNPayload)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .webClip(let p): try p.encode(to: encoder)
        case .wifi(let p): try p.encode(to: encoder)
        case .mail(let p): try p.encode(to: encoder)
        case .caldav(let p): try p.encode(to: encoder)
        case .carddav(let p): try p.encode(to: encoder)
        case .vpn(let p): try p.encode(to: encoder)
        }
    }
}

struct Profile: Encodable {
    let PayloadContent: [Payload]
    let PayloadType = "Configuration"
    let PayloadVersion = 1
    let PayloadIdentifier: String
    let PayloadUUID: String
    let PayloadDisplayName: String
    let PayloadRemovalDisallowed = false
}

/// Assigns a fresh `PayloadUUID` / `PayloadIdentifier` pair to a payload,
/// following the `"\(prefix).\(uuid)"` convention used throughout iosbk.
enum PayloadIdentity {
    static func make(prefix: String) -> (uuid: String, identifier: String) {
        let uuid = UUID().uuidString
        return (uuid, "\(prefix).\(uuid)")
    }
}

enum ProfileBuilder {
    /// Merges heterogeneous payloads into a single `.mobileconfig` XML plist.
    static func build(
        _ payloads: [Payload],
        displayName: String = "iosbk restore",
        prefix: String = "com.local.iosbk"
    ) throws -> Data {
        let profile = Profile(
            PayloadContent: payloads,
            PayloadIdentifier: prefix,
            PayloadUUID: UUID().uuidString,
            PayloadDisplayName: displayName)
        let enc = PropertyListEncoder()
        enc.outputFormat = .xml
        return try enc.encode(profile)
    }
}
