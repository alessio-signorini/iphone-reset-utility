import Foundation

/// Parses the NSKeyedArchive blob stored in the `file` column of Manifest.db.
///
/// Each backup file entry carries its per-file encryption metadata in a
/// binary plist (NSKeyedArchive of an `MBFile` object). The fields we need:
///
///   EncryptionKey  NSData  44 bytes:
///                            [0..<4]  protection class (little-endian UInt32)
///                            [4..<44] RFC 3394 wrapped AES-256 key (40 bytes)
///
/// Returns nil when the blob cannot be decoded or has no EncryptionKey
/// (possible for unencrypted files, which should not appear in encrypted backups).
enum MBFile {
    static func parse(_ data: Data) -> (protClass: UInt32, wrappedKey: Data, size: Int)? {
        guard let any = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) else {
            return nil
        }
        guard let archive = any as? [String: Any] else { return nil }
        guard let objects = archive["$objects"] as? [Any] else { return nil }
        guard let top = archive["$top"] as? [String: Any],
              let rootIdx = cfUID(top["root"]),
              rootIdx < objects.count,
              let root = objects[rootIdx] as? [String: Any] else {
            return nil
        }

        guard let keyRef = root["EncryptionKey"] else { return nil }
        guard let keyIdx = cfUID(keyRef), keyIdx < objects.count else { return nil }
        guard let keyData = nsData(objects[keyIdx]), keyData.count >= 44 else { return nil }

        let protClass  = keyData[0..<4].withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
        let wrappedKey = Data(keyData[4..<44])

        // The true (unpadded) plaintext length, so callers can strip the
        // AES block padding that pads the stored ciphertext.
        let size = resolveInt(root["Size"], in: objects) ?? -1
        return (protClass, wrappedKey, size)
    }

    /// Resolves an NSKeyedArchive value that may be either an inline integer
    /// or a `{"CF$UID": N}` reference to an integer in `$objects`.
    private static func resolveInt(_ value: Any?, in objects: [Any]) -> Int? {
        if let n = value as? Int { return n }
        if let idx = cfUID(value), idx < objects.count {
            if let n = objects[idx] as? Int { return n }
            if let n = objects[idx] as? Int64 { return Int(n) }
            if let n = objects[idx] as? UInt64 { return Int(n) }
        }
        return nil
    }

    /// Resolves an `EncryptionKey` value, which in an NSKeyedArchive is an
    /// `NSData`/`NSMutableData` wrapper dict `{"$class": …, "NS.data": <bytes>}`
    /// rather than a plain plist data node.
    private static func nsData(_ value: Any) -> Data? {
        if let d = value as? Data { return d }
        if let dict = value as? [String: Any], let d = dict["NS.data"] as? Data { return d }
        return nil
    }

    /// Resolves a keyed-archive UID reference to its integer index.
    ///
    /// `PropertyListSerialization` decodes archive UIDs as opaque
    /// `CFKeyedArchiverUID` objects (whose description is `…{value = N}`),
    /// not as the `{"CF$UID": N}` dictionaries that some other decoders emit.
    /// Handle both, plus a plain integer, so the parser is decoder-agnostic.
    private static func cfUID(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let n = value as? Int { return n }
        if let dict = value as? [String: Any], let n = dict["CF$UID"] as? Int { return n }
        // CFKeyedArchiverUID: extract N from its "{value = N}" description.
        let desc = String(describing: value)
        if let r = desc.range(of: "value = ") {
            let digits = desc[r.upperBound...].prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }
}
