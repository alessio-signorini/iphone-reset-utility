import Foundation
import CryptoKit

/// Extracts certificates from the backup keychain and turns them into
/// certificate payloads for a restore profile.
///
/// Certificates live in the keychain (`cert` items in `keychain-backup.plist`),
/// which is only decryptable in **encrypted** backups. Against an unencrypted
/// backup this plugin yields nothing.
///
/// The emitted `.mobileconfig` installs each certificate with a single tap —
/// the one genuinely auto-restorable item in the "installed profiles/certs"
/// family (the configuration profiles themselves are excluded from backups).
struct CertsPlugin: ExtractorPlugin {
    let key = "certs"
    let summary = "Certificates from the backup keychain (encrypted backups only)"

    func extract(_ backup: Backup, dryRun: Bool) throws -> [Keychain.Certificate] {
        let certs = backup.keychainCertificates()
        if dryRun && certs.isEmpty {
            FileHandle.standardError.write(
                "certs: no certificates found — the keychain is only decryptable in encrypted backups.\n"
                    .data(using: .utf8)!)
        }
        return certs
    }

    func describe(_ item: Keychain.Certificate) -> String {
        let fingerprint = SHA256.hash(data: item.der).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
        return "\(item.label) (\(item.der.count) bytes, sha256:\(fingerprint)…)"
    }

    func payloads(_ items: [Keychain.Certificate]) -> [Payload] {
        items.map { cert in
            let id = PayloadIdentity.make(prefix: "com.local.iosbk.cert")
            return .certificate(CertificatePayload(
                PayloadIdentifier: id.identifier,
                PayloadUUID: id.uuid,
                PayloadDisplayName: cert.label,
                PayloadCertificateFileName: Self.fileName(for: cert.label),
                PayloadContent: cert.der))
        }
    }

    /// A filesystem-safe `<label>.cer` name for the payload's file-name field.
    private static func fileName(for label: String) -> String {
        let base = String(label.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return (base.isEmpty ? "certificate" : base) + ".cer"
    }
}
