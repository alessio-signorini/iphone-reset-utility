import Foundation
import Testing
@testable import iosbk

@Suite("Certificates (keychain -> profile)")
struct CertsPluginTests {
    /// A synthetic keychain-item blob whose plaintext is arbitrary DER-ish bytes.
    private func certBlob(_ der: Data, clas: UInt32, classKey: Data) -> Data {
        TestCrypto.makeVersion0Blob(
            clas: clas, classKey: classKey, itemKey: TestCrypto.randomKey(), plaintext: der)
    }

    @Test("certificates() decrypts cert items into DER with labels")
    func decryptsCerts() throws {
        let clas: UInt32 = 3
        let classKey = TestCrypto.randomKey()
        let dec = BackupDecryptor(classKeys: [clas: classKey])

        let derA = Data([0x30, 0x82, 0x01, 0x0a, 0xDE, 0xAD])
        let derB = Data([0x30, 0x82, 0x02, 0x00, 0xBE, 0xEF])
        let plist: [String: Any] = [
            "cert": [
                ["labl": "My CA", "v_Data": certBlob(derA, clas: clas, classKey: classKey)],
                // No label -> falls back to acct.
                ["acct": "device-id", "v_Data": certBlob(derB, clas: clas, classKey: classKey)],
                // Undecryptable item (wrong class) is skipped.
                ["labl": "Broken", "v_Data": Data([0x00, 0x01, 0x02])],
            ],
        ]

        let certs = Keychain.certificates(plist: plist, decryptor: dec)
        #expect(certs.count == 2)
        #expect(certs.first { $0.label == "My CA" }?.der == derA)
        #expect(certs.first { $0.label == "device-id" }?.der == derB)
    }

    @Test("certificates() returns empty when there is no cert class")
    func noCertClass() {
        let dec = BackupDecryptor(classKeys: [:])
        #expect(Keychain.certificates(plist: ["genp": []], decryptor: dec).isEmpty)
    }

    @Test("payloads emit com.apple.security.pkcs1 with DER content")
    func emitsCertPayload() throws {
        let der = Data([0x30, 0x82, 0x01, 0x00, 0x11, 0x22])
        let certs = [Keychain.Certificate(label: "Corp Root CA", der: der)]
        let payloads = CertsPlugin().payloads(certs)
        let data = try ProfileBuilder.build(payloads)

        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        let content = try #require((plist?["PayloadContent"]) as? [[String: Any]])
        let cert = try #require(content.first { $0["PayloadType"] as? String == "com.apple.security.pkcs1" })
        #expect(cert["PayloadContent"] as? Data == der)
        #expect(cert["PayloadDisplayName"] as? String == "Corp Root CA")
        #expect((cert["PayloadCertificateFileName"] as? String)?.hasSuffix(".cer") == true)
    }

    @Test("registered under the 'certs' plugin key")
    func registered() {
        #expect(Registry["certs"] != nil)
    }
}
