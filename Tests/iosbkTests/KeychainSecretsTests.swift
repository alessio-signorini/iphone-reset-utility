import Foundation
import Testing
@testable import iosbk

@Suite("Keychain account secrets")
struct KeychainSecretsTests {
    @Test("secrets() decrypts genp and inet password items with their attributes")
    func decryptsSecrets() throws {
        let clas: UInt32 = 3
        let classKey = TestCrypto.randomKey()
        let dec = BackupDecryptor(classKeys: [clas: classKey])
        func blob(_ s: String) -> Data {
            TestCrypto.makeVersion0Blob(
                clas: clas, classKey: classKey, itemKey: TestCrypto.randomKey(),
                plaintext: Data(s.utf8))
        }
        let plist: [String: Any] = [
            "inet": [
                ["srvr": "imap.example.com", "acct": "user@example.com",
                 "ptcl": "imap", "v_Data": blob("in-pass")],
            ],
            "genp": [
                ["svce": "VPN-Shared", "acct": "vpnuser", "labl": "XAUTH shared",
                 "v_Data": blob("shared-secret")],
            ],
        ]
        let secrets = Keychain.secrets(plist: plist, decryptor: dec)
        #expect(secrets.count == 2)
        let inet = try #require(secrets.first { $0.itemClass == "inet" })
        #expect(inet.server == "imap.example.com")
        #expect(inet.account == "user@example.com")
        #expect(inet.protocolType == "imap")
        #expect(inet.password == "in-pass")
    }

    @Test("mailPasswords matches by host/username and prefers protocol tags")
    func matchesMail() {
        let secrets = [
            Keychain.Secret(itemClass: "inet", account: "user@example.com",
                            server: "imap.example.com", service: nil,
                            protocolType: "imap", label: nil, password: "in-pass"),
            Keychain.Secret(itemClass: "inet", account: "user@example.com",
                            server: "smtp.example.com", service: nil,
                            protocolType: "smtp", label: nil, password: "out-pass"),
        ]
        let (incoming, outgoing) = Keychain.mailPasswords(
            host: "imap.example.com", username: "user@example.com", in: secrets)
        #expect(incoming == "in-pass")
        #expect(outgoing == "out-pass")

        // No match -> nils.
        let none = Keychain.mailPasswords(host: "other.com", username: "nobody", in: secrets)
        #expect(none.incoming == nil)
        #expect(none.outgoing == nil)
    }

    @Test("vpnSecrets separates the shared secret from the user password")
    func matchesVPN() {
        let secrets = [
            Keychain.Secret(itemClass: "genp", account: "vpnuser", server: nil,
                            service: "Work VPN", protocolType: nil, label: nil, password: "user-pass"),
            Keychain.Secret(itemClass: "genp", account: "vpnuser", server: nil,
                            service: "Work VPN", protocolType: nil, label: "IPSec Shared Secret",
                            password: "the-shared-secret"),
        ]
        let (password, shared) = Keychain.vpnSecrets(
            username: "vpnuser", description: "Work VPN", in: secrets)
        #expect(password == "user-pass")
        #expect(shared == "the-shared-secret")
    }

    @Test("enriched mail/VPN entries emit password keys in the profile")
    func payloadsCarryPasswords() throws {
        let entries = [
            AccountEntry(kind: .mail, description: "Work Mail",
                         hostName: "imap.example.com", username: "user@example.com",
                         incomingPassword: "in-pass", outgoingPassword: "out-pass"),
            AccountEntry(kind: .vpn, description: "Work VPN",
                         hostName: "vpn.example.com", username: "vpnuser",
                         vpnPassword: "user-pass", sharedSecret: "the-shared-secret"),
        ]
        let payloads = AccountsPlugin().payloads(entries)
        let data = try ProfileBuilder.build(payloads)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        let content = try #require((plist?["PayloadContent"]) as? [[String: Any]])

        let mail = try #require(content.first { $0["PayloadType"] as? String == "com.apple.mail.managed" })
        #expect(mail["IncomingPassword"] as? String == "in-pass")
        #expect(mail["OutgoingPassword"] as? String == "out-pass")

        let vpn = try #require(content.first { $0["PayloadType"] as? String == "com.apple.vpn.managed" })
        #expect(vpn["VPNPassword"] as? String == "user-pass")
        #expect(vpn["SharedSecret"] as? String == "the-shared-secret")
    }
}
