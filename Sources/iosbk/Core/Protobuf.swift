import Foundation

/// A single decoded protobuf field value, before it's interpreted as a
/// specific message type. Wire type 3/4 (groups) are unsupported (unused by
/// anything in Notes) and cause `Protobuf.fields` to bail out.
enum ProtoValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case length(Data)
    case fixed32(UInt32)

    var varintValue: UInt64? { if case .varint(let v) = self { return v }; return nil }
    var dataValue: Data? { if case .length(let d) = self { return d }; return nil }
    var stringValue: String? { dataValue.map { String(decoding: $0, as: UTF8.self) } }
}

/// A minimal, generic protobuf (proto2/proto3 wire format) decoder. Notes
/// stores its rich content as several distinct, undocumented protobuf message
/// types (see `Core/NotesExport.swift`, `Core/NotesTable.swift`), so rather
/// than generating per-message Swift types, callers read fields out of the
/// flat `[fieldNumber: [ProtoValue]]` map this produces.
enum Protobuf {
    /// Decodes `data` into every top-level field, grouped by field number in
    /// encounter order (matters for `repeated` fields). Returns `nil` if the
    /// buffer isn't well-formed protobuf.
    static func fields(_ data: Data) -> [Int: [ProtoValue]]? {
        var result: [Int: [ProtoValue]] = [:]
        let bytes = [UInt8](data)
        var idx = 0
        while idx < bytes.count {
            guard let (key, keyEnd) = varint(bytes, idx) else { return nil }
            idx = keyEnd
            let fieldNum = Int(key >> 3)
            switch key & 0x7 {
            case 0: // varint
                guard let (v, end) = varint(bytes, idx) else { return nil }
                result[fieldNum, default: []].append(.varint(v))
                idx = end
            case 1: // 64-bit, little-endian
                guard idx + 8 <= bytes.count else { return nil }
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(bytes[idx + i]) << (8 * i) }
                result[fieldNum, default: []].append(.fixed64(v))
                idx += 8
            case 2: // length-delimited
                guard let (len, lenEnd) = varint(bytes, idx) else { return nil }
                let end = lenEnd + Int(len)
                guard end <= bytes.count else { return nil }
                result[fieldNum, default: []].append(.length(Data(bytes[lenEnd..<end])))
                idx = end
            case 5: // 32-bit, little-endian
                guard idx + 4 <= bytes.count else { return nil }
                var v: UInt32 = 0
                for i in 0..<4 { v |= UInt32(bytes[idx + i]) << (8 * i) }
                result[fieldNum, default: []].append(.fixed32(v))
                idx += 4
            default:
                return nil // groups (wire types 3/4): unused by Notes, unsupported
            }
        }
        return result
    }

    /// Reads a base-128 varint at `offset`, returning its value and the index
    /// just past it, or `nil` if the buffer ends mid-varint.
    static func varint(_ bytes: [UInt8], _ offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var idx = offset
        while idx < bytes.count {
            let byte = bytes[idx]
            result |= UInt64(byte & 0x7f) << shift
            idx += 1
            if byte & 0x80 == 0 { return (result, idx) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}

/// Convenience accessors treating a decoded field map as a single message
/// (i.e. reading its *first* occurrence of each field — right for all the
/// optional, non-repeated fields Notes' formats use).
extension Dictionary where Key == Int, Value == [ProtoValue] {
    func varint(_ field: Int) -> UInt64? { self[field]?.first?.varintValue }
    func data(_ field: Int) -> Data? { self[field]?.first?.dataValue }
    func string(_ field: Int) -> String? { self[field]?.first?.stringValue }
    func message(_ field: Int) -> [Int: [ProtoValue]]? { data(field).flatMap(Protobuf.fields) }
    func repeatedData(_ field: Int) -> [Data] { (self[field] ?? []).compactMap { $0.dataValue } }
}

/// Every protobuf blob in `NoteStore.sqlite` (note text, tables, drawings) is
/// wrapped in the same versioned-document envelope:
/// `Document{ repeated Version version = 2 }`, `Version{ optional bytes data = 3 }`.
/// (Schema per community reverse-engineering, e.g. dunhamsteve/notesutils.)
enum ProtoDocument {
    /// Unwraps the envelope and returns the inner `data` bytes, or `nil` if
    /// it doesn't match.
    static func payload(_ data: Data) -> Data? {
        Protobuf.fields(data)?.message(2)?.data(3)
    }
}
