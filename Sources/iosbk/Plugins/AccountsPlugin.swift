import Foundation

enum AccountKind: String, Encodable, Equatable {
    case mail
    case caldav
    case carddav
    case vpn
    case other
}

struct AccountEntry: Encodable {
    let kind: AccountKind
    let description: String
    let hostName: String?
    let username: String?
    /// The account's raw iOS account-type label (e.g. "CalDAV", "IMAP",
    /// "SMTP"), straight from `ZACCOUNTTYPE`. Display-only — never used for
    /// restore logic (`kind` still drives that) — but it's what lets two
    /// accounts sharing the same `description` (e.g. a personal server
    /// exposing both CalDAV and CardDAV under the same hostname) be told
    /// apart in `describe()`.
    var typeLabel: String? = nil
    /// Cleartext secrets from the backup keychain, only attached by
    /// `withKeychainPasswords` for `profile --with-passwords`. nil -> omitted.
    var incomingPassword: String? = nil
    var outgoingPassword: String? = nil
    var vpnPassword: String? = nil
    var sharedSecret: String? = nil
}

/// Extracts Mail/CalDAV/CardDAV/VPN accounts from
/// `HomeDomain/Library/Accounts/Accounts3.sqlite`.
///
/// // VERIFY: the `Accounts3.sqlite` schema (`ZACCOUNT`, `ZACCOUNTTYPE`,
/// `ZDATACLASS` table/column names) varies across iOS versions. This plugin
/// reads defensively — a missing table/column causes that row (or account
/// type) to be skipped and logged under `--dry-run`, not a hard failure.
/// Confirm the schema against a real backup and record findings in the PR
/// under "Verified on-device".
struct AccountsPlugin: ExtractorPlugin {
    let key = "accounts"
    let summary = "Mail/CalDAV/CardDAV/VPN accounts (with password/secret, when recovered from an encrypted backup)"

    func extract(_ backup: Backup, dryRun: Bool) throws -> [AccountEntry] {
        let matches = try backup.files(domain: "HomeDomain", pathLike: "Library/Accounts/Accounts3.sqlite")
        guard let file = matches.first else {
            if dryRun {
                FileHandle.standardError.write(
                    "accounts: Accounts3.sqlite not found in HomeDomain\n".data(using: .utf8)!)
                let accountsFiles = (try? backup.files(domain: "HomeDomain", pathLike: "Library/Accounts/%")) ?? []
                if accountsFiles.isEmpty {
                    FileHandle.standardError.write(
                        "accounts: HomeDomain/Library/Accounts/ is empty or not present in this backup\n"
                            .data(using: .utf8)!)
                } else {
                    FileHandle.standardError.write(
                        "accounts: files present in HomeDomain/Library/Accounts/:\n".data(using: .utf8)!)
                    for f in accountsFiles {
                        FileHandle.standardError.write("  \(f.rel)\n".data(using: .utf8)!)
                    }
                }
            }
            return []
        }

        let db: Sqlite
        do {
            db = try backup.openSqlite(file)
        } catch {
            if dryRun {
                FileHandle.standardError.write(
                    "accounts: Accounts3.sqlite could not be opened: \(error)\n".data(using: .utf8)!)
            }
            return []
        }

        // A database with no tables is the placeholder iOS writes in unencrypted
        // backups; the real account data is only present in encrypted backups.
        let tables = (try? db.query("SELECT name FROM sqlite_master WHERE type='table'"))
            .map { rows in rows.compactMap { $0.string("name") } } ?? []
        if tables.isEmpty {
            FileHandle.standardError.write(
                "accounts: Accounts3.sqlite has no tables — iOS only includes account data in encrypted backups.\n"
                    .data(using: .utf8)!)
            return []
        }

        return Self.readAccounts(db, dryRun: dryRun)
    }

    func describe(_ item: AccountEntry) -> String {
        var s = "\(item.kind.rawValue): \(item.description)"
        if let hostName = item.hostName { s += " @ \(hostName)" }
        if let username = item.username { s += " (\(username))" }
        if let typeLabel = item.typeLabel { s += " [\(typeLabel)]" }
        return s
    }

    func payloads(_ items: [AccountEntry]) -> [Payload] {
        items.compactMap { entry in
            switch entry.kind {
            case .mail:
                let id = PayloadIdentity.make(prefix: "com.local.iosbk.mail")
                return .mail(MailPayload(
                    PayloadIdentifier: id.identifier,
                    PayloadUUID: id.uuid,
                    PayloadDisplayName: entry.description,
                    EmailAccountDescription: entry.description,
                    EmailAccountName: entry.description,
                    EmailAddress: entry.username,
                    IncomingMailServerHostName: entry.hostName,
                    IncomingMailServerUsername: entry.username,
                    OutgoingMailServerHostName: entry.hostName,
                    OutgoingMailServerUsername: entry.username,
                    IncomingPassword: entry.incomingPassword,
                    OutgoingPassword: entry.outgoingPassword))
            case .caldav:
                let id = PayloadIdentity.make(prefix: "com.local.iosbk.caldav")
                return .caldav(CalDAVPayload(
                    PayloadIdentifier: id.identifier,
                    PayloadUUID: id.uuid,
                    PayloadDisplayName: entry.description,
                    CalDAVAccountDescription: entry.description,
                    CalDAVHostName: entry.hostName ?? "",
                    CalDAVUsername: entry.username))
            case .carddav:
                let id = PayloadIdentity.make(prefix: "com.local.iosbk.carddav")
                return .carddav(CardDAVPayload(
                    PayloadIdentifier: id.identifier,
                    PayloadUUID: id.uuid,
                    PayloadDisplayName: entry.description,
                    CardDAVAccountDescription: entry.description,
                    CardDAVHostName: entry.hostName ?? "",
                    CardDAVUsername: entry.username))
            case .vpn:
                let id = PayloadIdentity.make(prefix: "com.local.iosbk.vpn")
                return .vpn(VPNPayload(
                    PayloadIdentifier: id.identifier,
                    PayloadUUID: id.uuid,
                    PayloadDisplayName: entry.description,
                    UserDefinedName: entry.description,
                    VPNSubType: nil,
                    VPNUsername: entry.username,
                    VPNServer: entry.hostName,
                    VPNPassword: entry.vpnPassword,
                    SharedSecret: entry.sharedSecret))
            case .other:
                return nil
            }
        }
    }

    /// Returns a copy of `entries` with mail/VPN secrets recovered from the
    /// backup keychain attached. Used by `profile --with-passwords`; requires
    /// an encrypted backup (unencrypted backups have no decryptable keychain,
    /// in which case the entries are returned unchanged).
    func withKeychainPasswords(_ entries: [AccountEntry], backup: Backup) -> [AccountEntry] {
        let secrets = backup.keychainSecrets()
        guard !secrets.isEmpty else { return entries }
        return entries.map { entry in
            var e = entry
            switch entry.kind {
            case .mail:
                let (inc, out) = Keychain.mailPasswords(
                    host: entry.hostName, username: entry.username, in: secrets)
                e.incomingPassword = inc
                e.outgoingPassword = out
            case .vpn:
                let (pw, shared) = Keychain.vpnSecrets(
                    username: entry.username, description: entry.description, in: secrets)
                e.vpnPassword = pw
                e.sharedSecret = shared
            default:
                break
            }
            return e
        }
    }

    /// Reads `ZACCOUNT` joined (defensively) with `ZACCOUNTTYPE`, mapping
    /// each account's type identifier to an `AccountKind`. Any row missing
    /// the columns we need is skipped rather than crashing the whole read.
    static func readAccounts(_ db: Sqlite, dryRun: Bool) -> [AccountEntry] {
        // Try the modern two-table join first; fall back to reading
        // ZACCOUNT alone if ZACCOUNTTYPE (or the join) isn't available.
        let joined = try? db.query("""
            SELECT ZACCOUNT.ZACCOUNTDESCRIPTION AS descr,
                   ZACCOUNT.ZUSERNAME AS username,
                   ZACCOUNT.ZSERVER AS server,
                   ZACCOUNTTYPE.ZACCOUNTTYPEDESCRIPTION AS typeDescr,
                   ZACCOUNTTYPE.ZIDENTIFIER AS typeID
            FROM ZACCOUNT
            LEFT JOIN ZACCOUNTTYPE ON ZACCOUNT.ZACCOUNTTYPE = ZACCOUNTTYPE.Z_PK
            """)

        let rows: [Sqlite.Row]
        if let joined {
            rows = joined
        } else if let fallback = try? db.query("SELECT * FROM ZACCOUNT") {
            if dryRun {
                FileHandle.standardError.write(
                    "accounts: ZACCOUNTTYPE join unavailable; reading ZACCOUNT only\n".data(using: .utf8)!)
            }
            rows = fallback
        } else {
            if dryRun {
                let schema = (try? db.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"))
                    .map { rows in rows.compactMap { $0.string("name") } } ?? []
                FileHandle.standardError.write(
                    "accounts: ZACCOUNT table not found; schema: \(schema)\n".data(using: .utf8)!)
            }
            return []
        }

        return rows.compactMap { row in
            guard let description = row.string("descr") ?? row.string("ZACCOUNTDESCRIPTION") else {
                return nil // skip: no usable label for this row
            }
            let username = row.string("username") ?? row.string("ZUSERNAME")
            let server = row.string("server") ?? row.string("ZSERVER")
            let rawTypeID = row.string("typeID") ?? ""
            let rawTypeDescr = row.string("typeDescr") ?? ""
            let kind = classify(typeID: rawTypeID.lowercased(), typeDescr: rawTypeDescr.lowercased())
            let typeLabel = rawTypeDescr.isEmpty ? (rawTypeID.isEmpty ? nil : rawTypeID) : rawTypeDescr
            return AccountEntry(kind: kind, description: description, hostName: server, username: username, typeLabel: typeLabel)
        }
    }

    private static func classify(typeID: String, typeDescr: String) -> AccountKind {
        let hay = typeID + " " + typeDescr
        if hay.contains("caldav") { return .caldav }
        if hay.contains("carddav") { return .carddav }
        if hay.contains("vpn") { return .vpn }
        if hay.contains("mail") || hay.contains("imap") || hay.contains("pop") { return .mail }
        return .other
    }
}
