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
    let summary = "Mail/CalDAV/CardDAV/VPN accounts (server/user only, no passwords)"

    func extract(_ backup: Backup, dryRun: Bool) throws -> [AccountEntry] {
        let matches = try backup.files(domain: "HomeDomain", pathLike: "Library/Accounts/Accounts3.sqlite")
        guard let file = matches.first else {
            if dryRun {
                FileHandle.standardError.write(
                    "accounts: Accounts3.sqlite not found in HomeDomain\n".data(using: .utf8)!)
            }
            return []
        }

        guard let db = try? backup.openSqlite(file) else {
            if dryRun {
                FileHandle.standardError.write(
                    "accounts: Accounts3.sqlite could not be opened\n".data(using: .utf8)!)
            }
            return []
        }

        return Self.readAccounts(db, dryRun: dryRun)
    }

    func describe(_ item: AccountEntry) -> String {
        "\(item.kind.rawValue): \(item.description)" + (item.hostName.map { " @ \($0)" } ?? "")
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
                    OutgoingMailServerUsername: entry.username))
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
                    VPNServer: entry.hostName))
            case .other:
                return nil
            }
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
                FileHandle.standardError.write(
                    "accounts: ZACCOUNT table unavailable/unreadable with expected columns\n"
                        .data(using: .utf8)!)
            }
            return []
        }

        return rows.compactMap { row in
            guard let description = row.string("descr") ?? row.string("ZACCOUNTDESCRIPTION") else {
                return nil // skip: no usable label for this row
            }
            let username = row.string("username") ?? row.string("ZUSERNAME")
            let server = row.string("server") ?? row.string("ZSERVER")
            let typeID = (row.string("typeID") ?? "").lowercased()
            let typeDescr = (row.string("typeDescr") ?? "").lowercased()
            let kind = classify(typeID: typeID, typeDescr: typeDescr)
            return AccountEntry(kind: kind, description: description, hostName: server, username: username)
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
