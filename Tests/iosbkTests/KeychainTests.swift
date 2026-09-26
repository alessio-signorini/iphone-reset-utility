import Foundation
import Testing
@testable import iosbk

@Suite("Keychain Wi-Fi passwords")
struct KeychainTests {
    @Test("decryptKeychainBlob round-trips a version-0 blob")
    func decryptsVersion0Blob() throws {
        let clas: UInt32 = 3
        let classKey = TestCrypto.randomKey()
        let itemKey = TestCrypto.randomKey()
        let secret = Data("hunter2-wifi-pass".utf8)
        let blob = TestCrypto.makeVersion0Blob(
            clas: clas, classKey: classKey, itemKey: itemKey, plaintext: secret)

        let dec = BackupDecryptor(classKeys: [clas: classKey])
        #expect(dec.decryptKeychainBlob(blob) == secret)
    }

    @Test("decryptKeychainBlob returns nil for unknown class or bad version")
    func rejectsBadBlobs() throws {
        let clas: UInt32 = 3
        let classKey = TestCrypto.randomKey()
        let blob = TestCrypto.makeVersion0Blob(
            clas: clas, classKey: classKey, itemKey: TestCrypto.randomKey(),
            plaintext: Data("x".utf8))

        // No class key available.
        #expect(BackupDecryptor(classKeys: [:]).decryptKeychainBlob(blob) == nil)
        // Truncated blob.
        #expect(BackupDecryptor(classKeys: [clas: classKey]).decryptKeychainBlob(blob.prefix(20)) == nil)
    }

    @Test("wifiPasswords maps AirPort genp items by SSID")
    func extractsAirPortPasswords() throws {
        let clas: UInt32 = 3
        let classKey = TestCrypto.randomKey()
        let dec = BackupDecryptor(classKeys: [clas: classKey])

        func blob(_ s: String) -> Data {
            TestCrypto.makeVersion0Blob(
                clas: clas, classKey: classKey, itemKey: TestCrypto.randomKey(),
                plaintext: Data(s.utf8))
        }

        let plist: [String: Any] = [
            "genp": [
                ["svce": "AirPort", "acct": "HomeNet", "v_Data": blob("home-pass")],
                // Account stored as raw UTF-8 Data rather than String.
                ["svce": "AirPort", "acct": Data("Office".utf8), "v_Data": blob("office-pass")],
                // Non-Wi-Fi item is ignored.
                ["svce": "com.apple.account", "acct": "me@example.com", "v_Data": blob("nope")],
            ],
        ]

        let passwords = Keychain.wifiPasswords(plist: plist, decryptor: dec)
        #expect(passwords == ["HomeNet": "home-pass", "Office": "office-pass"])
    }
}
