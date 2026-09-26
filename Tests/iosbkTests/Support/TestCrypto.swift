import Foundation
import CommonCrypto

/// Test-only crypto helpers for constructing synthetic keychain blobs so the
/// version-0 decryption path can be exercised without a real device backup.
enum TestCrypto {
    /// Builds a "version 0" keychain item blob:
    ///   [version LE 4][class LE 4][RFC3394-wrapped item key 40][AES-CBC ct].
    /// The ciphertext is `plaintext` PKCS7-padded and AES-256-CBC encrypted
    /// (zero IV) with `itemKey`, whose RFC 3394 wrapping under `classKey`
    /// forms the middle field.
    static func makeVersion0Blob(
        clas: UInt32, classKey: Data, itemKey: Data, plaintext: Data
    ) -> Data {
        var blob = Data()
        blob.append(le32(0))
        blob.append(le32(clas))
        blob.append(aesKeyWrap(kek: classKey, raw: itemKey))
        blob.append(aesCBCEncrypt(key: itemKey, data: pkcs7(plaintext)))
        return blob
    }

    static func randomKey(_ count: Int = 32) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func le32(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }

    private static func pkcs7(_ data: Data) -> Data {
        let pad = 16 - (data.count % 16)
        return data + Data(repeating: UInt8(pad), count: pad)
    }

    private static func aesKeyWrap(kek: Data, raw: Data) -> Data {
        let iv = Array(repeating: UInt8(0xA6), count: 8)
        var wrappedLen = raw.count + 8
        var wrapped = Data(count: wrappedLen)
        let rc = wrapped.withUnsafeMutableBytes { wPtr in
            kek.withUnsafeBytes { kPtr in
                raw.withUnsafeBytes { rPtr in
                    CCSymmetricKeyWrap(
                        CCWrappingAlgorithm(kCCWRAPAES), iv, iv.count,
                        kPtr.bindMemory(to: UInt8.self).baseAddress, kek.count,
                        rPtr.bindMemory(to: UInt8.self).baseAddress, raw.count,
                        wPtr.bindMemory(to: UInt8.self).baseAddress, &wrappedLen)
                }
            }
        }
        precondition(rc == kCCSuccess, "key wrap failed: \(rc)")
        return wrapped.prefix(wrappedLen)
    }

    private static func aesCBCEncrypt(key: Data, data: Data) -> Data {
        let iv = Data(count: kCCBlockSizeAES128)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let rc = out.withUnsafeMutableBytes { oPtr in
            key.withUnsafeBytes { kPtr in
                iv.withUnsafeBytes { iPtr in
                    data.withUnsafeBytes { dPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            0, // no padding: we pre-pad with PKCS7
                            kPtr.baseAddress, key.count,
                            iPtr.baseAddress,
                            dPtr.baseAddress, data.count,
                            oPtr.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        precondition(rc == kCCSuccess, "AES-CBC encrypt failed: \(rc)")
        return out.prefix(moved)
    }
}
