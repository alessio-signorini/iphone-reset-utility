import Foundation
import Testing
@testable import iosbk

@Suite("BackupDecryptor crypto primitives")
struct BackupDecryptorTests {

    // MARK: - PBKDF2-HMAC-SHA256

    /// Known test vector from Python hashlib:
    ///   hashlib.pbkdf2_hmac('sha256', b'password', b'salt', 4096).hex()
    ///   → c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a
    @Test("PBKDF2-SHA256 known test vector (c=4096)")
    func pbkdf2KnownVector4096() throws {
        let dk = try BackupDecryptor.pbkdf2SHA256(
            password: "password",
            salt: Data("salt".utf8),
            iterations: 4096)
        let expected = Data([
            0xc5, 0xe4, 0x78, 0xd5, 0x92, 0x88, 0xc8, 0x41,
            0xaa, 0x53, 0x0d, 0xb6, 0x84, 0x5c, 0x4c, 0x8d,
            0x96, 0x28, 0x93, 0xa0, 0x01, 0xce, 0x4e, 0x11,
            0xa4, 0x96, 0x38, 0x73, 0xaa, 0x98, 0x13, 0x4a,
        ])
        #expect(dk == expected)
    }

    @Test("PBKDF2-SHA256 output is 32 bytes, deterministic, and sensitive to iteration count")
    func pbkdf2SanityChecks() throws {
        let a = try BackupDecryptor.pbkdf2SHA256(password: "pw", salt: Data("s".utf8), iterations: 1)
        let b = try BackupDecryptor.pbkdf2SHA256(password: "pw", salt: Data("s".utf8), iterations: 1)
        let c = try BackupDecryptor.pbkdf2SHA256(password: "pw", salt: Data("s".utf8), iterations: 2)
        #expect(a.count == 32)
        #expect(a == b)  // deterministic
        #expect(a != c)  // different iteration count → different output
    }

    // MARK: - RFC 3394 AES key unwrap

    /// RFC 3394 §4.1 test vector:
    /// KEK (AES-128) = 000102030405060708090A0B0C0D0E0F
    /// Key Data      = 00112233445566778899AABBCCDDEEFF
    /// Ciphertext    = 1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5
    @Test("RFC 3394 AES key unwrap — NIST 128-bit test vector")
    func aesKeyUnwrapNIST128() throws {
        let kek = Data([
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        ])
        let wrapped = Data([
            0x1F, 0xA6, 0x8B, 0x0A, 0x81, 0x12, 0xB4, 0x47,
            0xAE, 0xF3, 0x4B, 0xD8, 0xFB, 0x5A, 0x7B, 0x82,
            0x9D, 0x3E, 0x86, 0x23, 0x71, 0xD2, 0xCF, 0xE5,
        ])
        let expected = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])
        let result = try BackupDecryptor.aesKeyUnwrap(kek: kek, wrapped: wrapped)
        #expect(result == expected)
    }

    /// Wrong KEK must cause an integrity-check failure, not a crash.
    @Test("RFC 3394 wrong KEK throws wrongPassword")
    func aesKeyUnwrapWrongKEK() throws {
        let kek     = Data(repeating: 0xFF, count: 16) // intentionally wrong
        let wrapped = Data([
            0x1F, 0xA6, 0x8B, 0x0A, 0x81, 0x12, 0xB4, 0x47,
            0xAE, 0xF3, 0x4B, 0xD8, 0xFB, 0x5A, 0x7B, 0x82,
            0x9D, 0x3E, 0x86, 0x23, 0x71, 0xD2, 0xCF, 0xE5,
        ])
        #expect(throws: BackupDecryptor.DecryptorError.wrongPassword) {
            _ = try BackupDecryptor.aesKeyUnwrap(kek: kek, wrapped: wrapped)
        }
    }

    // MARK: - AES-256-CBC decrypt

    /// NIST SP 800-38A §F.2.6 — AES-256-CBC decrypt test vector.
    /// Key  = 603deb10 15ca71be 2b73aef0 857d7781 1f352c07 3b6108d7 2d9810a3 0914dff4
    /// IV   = 00010203 04050607 08090a0b 0c0d0e0f
    /// CT   = f58c4c04 d6e5f1ba 779eabfb 5f7bfbd6 9cfc4e96 7edb808d 679f777b c6702c7d
    ///        39f23369 a9d9bacf a530e263 04231461 b2eb05e2 c39be9fc da6c1907 8c6a9d1b
    /// PT   = 6bc1bee2 2e409f96 e93d7e11 7393172a ae2d8a57 1e03ac9c 9eb76fac 45af8e51
    ///        30c81c46 a35ce411 e5fbc119 1a0a52ef f69f2445 df4f9b17 ad2b417b e66c3710
    @Test("AES-256-CBC decrypt — NIST test vector")
    func aesCBCNISTVector() throws {
        let key = Data([
            0x60, 0x3d, 0xeb, 0x10, 0x15, 0xca, 0x71, 0xbe,
            0x2b, 0x73, 0xae, 0xf0, 0x85, 0x7d, 0x77, 0x81,
            0x1f, 0x35, 0x2c, 0x07, 0x3b, 0x61, 0x08, 0xd7,
            0x2d, 0x98, 0x10, 0xa3, 0x09, 0x14, 0xdf, 0xf4,
        ])
        let iv = Data([
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        ])
        let ct = Data([
            0xf5, 0x8c, 0x4c, 0x04, 0xd6, 0xe5, 0xf1, 0xba,
            0x77, 0x9e, 0xab, 0xfb, 0x5f, 0x7b, 0xfb, 0xd6,
            0x9c, 0xfc, 0x4e, 0x96, 0x7e, 0xdb, 0x80, 0x8d,
            0x67, 0x9f, 0x77, 0x7b, 0xc6, 0x70, 0x2c, 0x7d,
            0x39, 0xf2, 0x33, 0x69, 0xa9, 0xd9, 0xba, 0xcf,
            0xa5, 0x30, 0xe2, 0x63, 0x04, 0x23, 0x14, 0x61,
            0xb2, 0xeb, 0x05, 0xe2, 0xc3, 0x9b, 0xe9, 0xfc,
            0xda, 0x6c, 0x19, 0x07, 0x8c, 0x6a, 0x9d, 0x1b,
        ])
        let expected = Data([
            0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
            0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
            0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c,
            0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51,
            0x30, 0xc8, 0x1c, 0x46, 0xa3, 0x5c, 0xe4, 0x11,
            0xe5, 0xfb, 0xc1, 0x19, 0x1a, 0x0a, 0x52, 0xef,
            0xf6, 0x9f, 0x24, 0x45, 0xdf, 0x4f, 0x9b, 0x17,
            0xad, 0x2b, 0x41, 0x7b, 0xe6, 0x6c, 0x37, 0x10,
        ])
        let result = try BackupDecryptor.aesCBCDecrypt(key: key, iv: iv, data: ct)
        #expect(result == expected)
    }

    @Test("AES-CBC decrypt of empty data returns empty data")
    func aesCBCEmpty() throws {
        let key = Data(repeating: 0, count: 32)
        let result = try BackupDecryptor.aesCBCDecrypt(key: key, data: Data())
        #expect(result.isEmpty)
    }

    // MARK: - MBFile

    @Test("MBFile.parse returns nil for non-archive data")
    func mbFileParseGarbage() {
        #expect(MBFile.parse(Data("not a plist".utf8)) == nil)
    }
}
