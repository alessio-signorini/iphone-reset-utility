import Foundation
import Compression

/// Minimal in-process gunzip. Apple's `Compression` framework only decodes a
/// raw DEFLATE stream (RFC 1951), so this parses the surrounding gzip
/// container (RFC 1952) — magic, flags, optional header fields, trailer — and
/// feeds the inner DEFLATE payload to `compression_decode_buffer`.
///
/// Used to inflate the per-note `ZDATA` blobs in Apple Notes'
/// `NoteStore.sqlite`, which are gzip-compressed protobuf.
enum Gzip {
    /// Inflates a gzip stream, or returns `nil` if `data` is not a well-formed
    /// gzip member. The CRC-32 trailer is not verified (the inner DEFLATE
    /// end-of-stream marker already bounds the output).
    static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        // 10-byte header + 8-byte trailer is the smallest possible member.
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            return nil
        }
        let flg = bytes[3]
        var idx = 10
        if flg & 0x04 != 0 { // FEXTRA: 2-byte length + payload
            guard idx + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if flg & 0x08 != 0 { // FNAME: NUL-terminated
            while idx < bytes.count && bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flg & 0x10 != 0 { // FCOMMENT: NUL-terminated
            while idx < bytes.count && bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flg & 0x02 != 0 { idx += 2 } // FHCRC: 2-byte header CRC
        guard idx <= bytes.count - 8 else { return nil }

        // Trailer's ISIZE (uncompressed size mod 2^32) sizes the output buffer.
        let n = bytes.count
        let isize = Int(bytes[n - 4]) | (Int(bytes[n - 3]) << 8)
            | (Int(bytes[n - 2]) << 16) | (Int(bytes[n - 1]) << 24)
        let deflate = Array(bytes[idx..<(n - 8)])
        guard !deflate.isEmpty else { return nil }

        var capacity = isize > 0 ? isize : max(deflate.count * 4, 65_536)
        while true {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let decoded = deflate.withUnsafeBufferPointer { src in
                compression_decode_buffer(
                    dst, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
            if decoded == 0 { return nil }
            // A full buffer with an unknown ISIZE may indicate truncation: grow
            // and retry. When ISIZE is known the buffer is sized exactly.
            if decoded == capacity && isize <= 0 {
                capacity *= 2
                if capacity > 64 * 1024 * 1024 { return nil }
                continue
            }
            return Data(bytes: dst, count: decoded)
        }
    }
}
