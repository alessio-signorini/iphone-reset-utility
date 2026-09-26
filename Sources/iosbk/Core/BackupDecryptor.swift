import Foundation
import CommonCrypto

/// Decrypts iOS encrypted backups (keybag type 1, iOS 9+).
///
/// Protocol:
///  1. Parse the BackupKeyBag TLV blob from Manifest.plist.
///  2. Derive KEK = PBKDF2-HMAC-SHA256(password, DPSL, DPIC iterations).
///  3. RFC 3394 AES key-unwrap every WRAP=2 entry → class keys.
///  4. Decrypt Manifest.db: read class from ManifestKey[0..<4] (LE),
///     unwrap ManifestKey[4..<44] with that class key, AES-256-CBC IV=0.
///  5. Per-file: parse the MBFile NSKeyedArchive blob → class + wrapped key,
///     unwrap with class key, AES-256-CBC IV=0.
struct BackupDecryptor: Sendable {

    enum DecryptorError: Error, CustomStringConvertible, Equatable {
        case invalidKeybag(String)
        case wrongPassword
        case decryptionFailed(String)

        var description: String {
            switch self {
            case .invalidKeybag(let r): return "BackupKeyBag invalid: \(r)"
            case .wrongPassword:        return "incorrect backup password"
            case .decryptionFailed(let r): return "decryption error: \(r)"
            }
        }
    }

    /// Unwrapped class keys, keyed by iOS protection-class number.
    private let classKeys: [UInt32: Data]

    // MARK: - Initialisation

    /// Test-only: builds a decryptor from pre-derived class keys, so
    /// keychain-blob decryption can be exercised without a full keybag/PBKDF2
    /// round-trip. Not used by the real extraction path.
    init(classKeys: [UInt32: Data]) {
        self.classKeys = classKeys
    }

    /// Parses the BackupKeyBag TLV and derives all class keys from `password`.
    /// Throws `.wrongPassword` when the password fails to unwrap any key.
    init(keybagData: Data, password: String) throws {
        // ── 1. Parse flat TLV stream ─────────────────────────────────────────
        var type: UInt32?
        var salt: Data?
        var iter: UInt32?
        var dpsl: Data?
        var dpic: UInt32?

        struct RawEntry { var clas: UInt32 = 0; var wrap: UInt32 = 0; var wpky = Data() }
        var entries: [RawEntry] = []
        var cur: RawEntry?

        var off = 0
        while off + 8 <= keybagData.count {
            let tag = String(bytes: keybagData[off..<off+4], encoding: .ascii) ?? ""
            let len = Int(keybagData[off+4..<off+8].withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            })
            off += 8
            guard off + len <= keybagData.count else {
                throw DecryptorError.invalidKeybag("TLV overrun at tag '\(tag)'")
            }
            let val = keybagData[off..<off+len]
            off += len

            let uint32be: () -> UInt32 = {
                val.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
            }

            switch tag {
            case "TYPE": type = uint32be()
            case "SALT": salt = Data(val)
            case "ITER": iter = uint32be()
            case "DPSL": dpsl = Data(val)
            case "DPIC": dpic = uint32be()
            case "UUID":
                if let c = cur { entries.append(c) }
                cur = RawEntry()
            case "CLAS": cur?.clas = uint32be()
            case "WRAP": if cur != nil { cur!.wrap = uint32be() }
            case "WPKY": cur?.wpky = Data(val)
            default:     break
            }
        }
        if let c = cur { entries.append(c) }

        guard type == 1 else {
            throw DecryptorError.invalidKeybag("expected keybag TYPE=1 (backup), got \(type ?? 0)")
        }
        guard let salt else { throw DecryptorError.invalidKeybag("SALT (PBKDF2-SHA1 salt) missing") }
        guard let iter else { throw DecryptorError.invalidKeybag("ITER (PBKDF2-SHA1 iterations) missing") }

        // ── 2. Derive KEK ────────────────────────────────────────────────────
        // Modern iOS backups (10.2+) use double PBKDF2: first stretch the
        // password with SHA-256 (DPSL/DPIC), then feed that into a SHA-1
        // round (SALT/ITER). Older backups have no DPSL/DPIC and use the
        // password directly in the SHA-1 round.
        let firstStage: Data
        if let dpsl, let dpic {
            firstStage = try Self.pbkdf2(
                password: Data(password.utf8), salt: dpsl,
                iterations: dpic, prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256))
        } else {
            firstStage = Data(password.utf8)
        }
        let kek = try Self.pbkdf2(
            password: firstStage, salt: salt,
            iterations: iter, prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1))

        // ── 3. Unwrap passcode-wrapped class keys (WRAP includes passcode) ──
        var keys: [UInt32: Data] = [:]
        for e in entries where (e.wrap & 2) != 0 && e.wpky.count == 40 {
            if let unwrapped = try? Self.aesKeyUnwrap(kek: kek, wrapped: e.wpky) {
                keys[e.clas] = unwrapped
            }
        }
        guard !keys.isEmpty else { throw DecryptorError.wrongPassword }
        self.classKeys = keys
    }

    // MARK: - Manifest.db

    /// Decrypts the encrypted `Manifest.db` bytes.
    ///
    /// `manifestKey` is the 44-byte blob from Manifest.plist:
    ///   bytes  0-3 : protection class (little-endian UInt32)
    ///   bytes 4-43 : RFC 3394 wrapped AES-256 key (40 bytes)
    func decryptManifestDB(manifestKey: Data, encryptedDB: Data) throws -> Data {
        guard manifestKey.count >= 44 else {
            throw DecryptorError.invalidKeybag("ManifestKey must be ≥ 44 bytes, got \(manifestKey.count)")
        }
        let protClass = manifestKey[0..<4].withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
        let wrapped = Data(manifestKey[4..<44])
        guard let classKey = classKeys[protClass] else {
            throw DecryptorError.decryptionFailed(
                "no class key for manifest protection class \(protClass); available: \(classKeys.keys.sorted())")
        }
        let dbKey = try Self.aesKeyUnwrap(kek: classKey, wrapped: wrapped)
        let plain = try Self.aesCBCDecrypt(key: dbKey, data: encryptedDB)
        // Sanity-check: decrypted data must start with the SQLite magic string.
        let magic = Data("SQLite format 3\0".utf8)
        guard plain.prefix(magic.count) == magic else {
            throw DecryptorError.wrongPassword
        }
        return plain
    }

    // MARK: - Per-file

    /// Parses the MBFile `fileBlob` from Manifest.db, unwraps the per-file
    /// AES-256 key, and AES-256-CBC decrypts `ciphertext` (IV = all-zeros).
    func decryptFile(fileBlob: Data?, ciphertext: Data) throws -> Data {
        if ciphertext.isEmpty { return Data() }
        guard let fileBlob else {
            throw DecryptorError.decryptionFailed("missing file metadata blob")
        }
        guard let (protClass, wrapped, size) = MBFile.parse(fileBlob) else {
            throw DecryptorError.decryptionFailed("unreadable MBFile blob")
        }
        guard let classKey = classKeys[protClass] else {
            throw DecryptorError.decryptionFailed(
                "no class key for file protection class \(protClass)")
        }
        let fileKey = try Self.aesKeyUnwrap(kek: classKey, wrapped: wrapped)
        let plain = try Self.aesCBCDecrypt(key: fileKey, data: ciphertext)
        // Strip AES block padding: the stored ciphertext is padded up to the
        // 16-byte boundary, but MBFile records the true plaintext length.
        if size >= 0 && size <= plain.count {
            return plain.prefix(size)
        }
        return plain
    }

    // MARK: - Keychain

    /// Decrypts a single backup-keychain item value blob (an item's `v_Data`).
    ///
    /// Backup keychain items use the classic "version 0" blob layout:
    ///   bytes  0-3  : version (little-endian UInt32, == 0)
    ///   bytes  4-7  : protection class (little-endian UInt32; low nibble is
    ///                 the class number, matching a backup-keybag class key)
    ///   bytes  8-47 : RFC 3394 wrapped AES-256 item key (40 bytes)
    ///   bytes 48-   : AES-256-CBC ciphertext (zero IV, PKCS7 padded)
    ///
    /// Returns nil (rather than throwing) when the blob is malformed, uses a
    /// newer AES-GCM layout (version 2/3, not produced by local encrypted
    /// backups), or no class key is available — keychain recovery is
    /// best-effort and must degrade gracefully.
    func decryptKeychainBlob(_ blob: Data) -> Data? {
        guard blob.count >= 48 else { return nil }
        let base = blob.startIndex
        let version = blob[base..<base+4].withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
        guard version == 0 else { return nil } // v2/v3 (AES-GCM) unsupported
        let clas = blob[base+4..<base+8].withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        } & 0xF
        guard let classKey = classKeys[clas] else { return nil }
        let wrapped = Data(blob[base+8..<base+48])
        let ciphertext = Data(blob[(base+48)...])
        guard let itemKey = try? Self.aesKeyUnwrap(kek: classKey, wrapped: wrapped),
              let plain = try? Self.aesCBCDecrypt(key: itemKey, data: ciphertext)
        else { return nil }
        return Self.stripPKCS7(plain)
    }

    /// Removes PKCS#7 padding (keychain item ciphertext is PKCS7-padded,
    /// unlike whole-file ciphertext which iOS truncates via the MBFile size).
    private static func stripPKCS7(_ data: Data) -> Data {
        guard let pad = data.last, pad >= 1, pad <= 16, data.count >= Int(pad) else { return data }
        let cut = data.count - Int(pad)
        return data[data.startIndex.advanced(by: cut)...].allSatisfy { $0 == pad }
            ? data.prefix(cut)
            : data
    }

    // MARK: - Crypto primitives (internal for testing)

    /// PBKDF2-HMAC-SHA256, output length fixed at 32 bytes.
    static func pbkdf2SHA256(password: String, salt: Data, iterations: UInt32) throws -> Data {
        try pbkdf2(password: Data(password.utf8), salt: salt,
                   iterations: iterations, prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256))
    }

    /// PBKDF2 with a configurable PRF, output length fixed at 32 bytes.
    /// `password` is raw bytes so it can be chained (SHA-256 stage feeding the
    /// SHA-1 stage, as modern iOS backups require).
    static func pbkdf2(password: Data, salt: Data, iterations: UInt32,
                       prf: CCPseudoRandomAlgorithm) throws -> Data {
        var derived = Data(repeating: 0, count: 32)
        let rc: CCCryptorStatus = derived.withUnsafeMutableBytes { dPtr in
            password.withUnsafeBytes { pPtr in
                salt.withUnsafeBytes { sPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pPtr.bindMemory(to: CChar.self).baseAddress, password.count,
                        sPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        prf,
                        iterations,
                        dPtr.bindMemory(to: UInt8.self).baseAddress!, 32)
                }
            }
        }
        guard rc == kCCSuccess else {
            throw DecryptorError.decryptionFailed("PBKDF2 failed (CCCryptorStatus \(rc))")
        }
        return derived
    }

    /// RFC 3394 AES key unwrap. `wrapped` must be a multiple of 8 bytes and
    /// at least 24 bytes (16-byte key + 8-byte integrity overhead).
    /// Throws `.wrongPassword` when the integrity check fails.
    static func aesKeyUnwrap(kek: Data, wrapped: Data) throws -> Data {
        let rfcIV: [UInt8] = [0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6]
        var rawLen = wrapped.count - 8
        var raw = Data(repeating: 0, count: rawLen)
        let rc: CCCryptorStatus = rfcIV.withUnsafeBytes { ivPtr in
            kek.withUnsafeBytes { kPtr in
                wrapped.withUnsafeBytes { wPtr in
                    raw.withUnsafeMutableBytes { rPtr in
                        CCSymmetricKeyUnwrap(
                            CCWrappingAlgorithm(kCCWRAPAES),
                            ivPtr.bindMemory(to: UInt8.self).baseAddress, rfcIV.count,
                            kPtr.bindMemory(to: UInt8.self).baseAddress,  kek.count,
                            wPtr.bindMemory(to: UInt8.self).baseAddress,  wrapped.count,
                            rPtr.bindMemory(to: UInt8.self).baseAddress!, &rawLen)
                    }
                }
            }
        }
        guard rc == kCCSuccess else { throw DecryptorError.wrongPassword }
        return Data(raw.prefix(rawLen))
    }

    /// AES-256-CBC decrypt. `iv` defaults to all-zeros (the iOS backup IV).
    /// Input must be a multiple of 16 bytes; iOS pre-pads files to the block
    /// boundary so PKCS7 padding removal is not applied here.
    static func aesCBCDecrypt(
        key: Data,
        iv: Data = Data(repeating: 0, count: 16),
        data: Data
    ) throws -> Data {
        guard !data.isEmpty else { return data }
        var outLen = 0
        var out = Data(repeating: 0, count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count  // capture before mutable borrow to avoid overlapping access
        let rc: CCCryptorStatus = key.withUnsafeBytes { kPtr in
            iv.withUnsafeBytes { iPtr in
                data.withUnsafeBytes { dPtr in
                    out.withUnsafeMutableBytes { oPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128), // block size; key size is inferred from keyLength
                            0,                               // no automatic PKCS7 padding
                            kPtr.bindMemory(to: UInt8.self).baseAddress, key.count,
                            iPtr.bindMemory(to: UInt8.self).baseAddress,
                            dPtr.bindMemory(to: UInt8.self).baseAddress, data.count,
                            oPtr.bindMemory(to: UInt8.self).baseAddress!, outCapacity,
                            &outLen)
                    }
                }
            }
        }
        guard rc == kCCSuccess else {
            throw DecryptorError.decryptionFailed("AES-CBC failed (CCCryptorStatus \(rc))")
        }
        return Data(out.prefix(outLen))
    }
}
