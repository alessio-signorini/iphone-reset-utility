import Foundation

/// Best-effort decoder for Apple Notes' embedded-table format: a
/// CRDT-flavored object graph (rows/columns are ordered sets of UUIDs, cell
/// text is keyed by `column UUID -> row UUID -> String`) layered on top of
/// the same protobuf primitives as everything else in Notes.
///
/// There is no public specification for this — it's reconstructed from
/// community reverse-engineering (dunhamsteve/notesutils) and has not been
/// verified against a real device/backup. Every step is written to fail soft
/// (return `nil`) on any structural mismatch rather than guess, so an
/// unrecognized/changed table shows a placeholder instead of garbled output.
/// // VERIFY: this whole decoder against a real backup containing tables.
enum NotesTable {
    private enum Resolved {
        case uuid(Data)
        case dictionary([Int: [ProtoValue]])
        case string([Int: [ProtoValue]])
    }

    /// Decodes a table's cell text as `rows[rowIndex][columnIndex]`, or `nil`
    /// if `data` doesn't match the expected shape.
    static func decode(_ data: Data) -> [[String]]? {
        let inflated = Gzip.inflate(data) ?? data
        guard let payload = ProtoDocument.payload(inflated), let root = Protobuf.fields(payload) else { return nil }

        let keyItems = (root[4] ?? []).compactMap { $0.stringValue }
        let uuidItems = root.repeatedData(6)
        let objects = root.repeatedData(3)

        guard let rootObject = objects.first, let rootFields = Protobuf.fields(rootObject),
              let custom = rootFields.message(13), let mapEntries = custom[3]
        else { return nil }

        var named: [String: Int] = [:] // "crRows"/"crColumns"/"cellColumns" -> objectIndex
        for entry in mapEntries {
            guard let ef = entry.dataValue.flatMap(Protobuf.fields),
                  let keyIdx = ef.varint(1).map(Int.init), keyIdx < keyItems.count,
                  let value = ef.message(2), let objIdx = value.varint(6).map(Int.init)
            else { continue }
            named[keyItems[keyIdx]] = objIdx
        }

        guard let rowsIdx = named["crRows"], let colsIdx = named["crColumns"], let cellsIdx = named["cellColumns"],
              rowsIdx < objects.count, colsIdx < objects.count, cellsIdx < objects.count,
              let rows = orderedUUIDs(objects[rowsIdx], objects: objects, keyItems: keyItems, uuidItems: uuidItems),
              let cols = orderedUUIDs(objects[colsIdx], objects: objects, keyItems: keyItems, uuidItems: uuidItems),
              let cellFields = Protobuf.fields(objects[cellsIdx]), let cellDict = cellFields.message(6),
              !rows.isEmpty, !cols.isEmpty
        else { return nil }

        return rows.map { row in
            cols.map { col in
                cellText(col: col, row: row, cellDict: cellDict, objects: objects, keyItems: keyItems, uuidItems: uuidItems) ?? ""
            }
        }
    }

    /// Renders a decoded grid as a Markdown table (first row as header).
    static func markdown(_ rows: [[String]]) -> String {
        guard let header = rows.first, !header.isEmpty else { return "" }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["| " + header.map(esc).joined(separator: " | ") + " |"]
        lines.append("| " + Array(repeating: "---", count: header.count).joined(separator: " | ") + " |")
        lines += rows.dropFirst().map { "| " + $0.map(esc).joined(separator: " | ") + " |" }
        return lines.joined(separator: "\n")
    }

    // MARK: - Object graph resolution

    /// Resolves an `ObjectID` message (`{ uint64 unsignedIntegerValue = 2;
    /// string stringValue = 4; uint32 objectIndex = 6; }`) to whatever it
    /// points at in `objects`: a UUID (via a `CustomObject` carrying a
    /// `UUIDIndex` map entry), a nested dictionary, or a cell's text.
    private static func resolve(
        _ objectID: [Int: [ProtoValue]], objects: [Data], keyItems: [String], uuidItems: [Data]
    ) -> Resolved? {
        guard let idx = objectID.varint(6).map(Int.init), idx < objects.count,
              let obj = Protobuf.fields(objects[idx])
        else { return nil }
        if let custom = obj.message(13) {
            guard let entries = custom[3] else { return nil }
            for entry in entries {
                guard let ef = entry.dataValue.flatMap(Protobuf.fields),
                      let keyIdx = ef.varint(1).map(Int.init), keyIdx < keyItems.count,
                      keyItems[keyIdx] == "UUIDIndex",
                      let value = ef.message(2), let uuidIdx = value.varint(2).map(Int.init), uuidIdx < uuidItems.count
                else { continue }
                return .uuid(uuidItems[uuidIdx])
            }
            return nil
        }
        if let dict = obj.message(6) { return .dictionary(dict) }
        if let str = obj.message(10) { return .string(str) }
        return nil
    }

    /// Reconstructs the row (or column) UUID order for an `OrderedSet`
    /// (`{ Array ordering = 1; Dictionary elements = 2; }`), filtering out
    /// entries that no longer appear in `elements` (deleted) and following
    /// `ordering.contents` to each position's actual referenced UUID.
    private static func orderedUUIDs(
        _ orderedSetObject: Data, objects: [Data], keyItems: [String], uuidItems: [Data]
    ) -> [Data]? {
        guard let f = Protobuf.fields(orderedSetObject), let orderedSet = f.message(16),
              let array = orderedSet.message(1), let ttArray = array.message(1)
        else { return nil }

        let positions = (ttArray[2] ?? []).compactMap { value -> (Int, Data)? in
            guard let af = value.dataValue.flatMap(Protobuf.fields),
                  let index = af.varint(1).map(Int.init), let uuid = af.data(2)
            else { return nil }
            return (index, uuid)
        }.sorted { $0.0 < $1.0 }
        guard !positions.isEmpty else { return nil }

        var live = Set<Data>()
        if let elements = orderedSet.message(2)?[1] {
            for element in elements {
                guard let ef = element.dataValue.flatMap(Protobuf.fields), let key = ef.message(1),
                      case .uuid(let uuid)? = resolve(key, objects: objects, keyItems: keyItems, uuidItems: uuidItems)
                else { continue }
                live.insert(uuid)
            }
        }
        let ordered = live.isEmpty ? positions.map(\.1) : positions.filter { live.contains($0.1) }.map(\.1)

        var contents: [Data: Data] = [:]
        if let elements = array.message(2)?[1] {
            for element in elements {
                guard let ef = element.dataValue.flatMap(Protobuf.fields),
                      let key = ef.message(1), case .uuid(let k)? = resolve(key, objects: objects, keyItems: keyItems, uuidItems: uuidItems),
                      let value = ef.message(2), case .uuid(let v)? = resolve(value, objects: objects, keyItems: keyItems, uuidItems: uuidItems)
                else { continue }
                contents[k] = v
            }
        }
        return ordered.map { contents[$0] ?? $0 }
    }

    /// Looks up a single cell's text in `cellColumns`
    /// (`Dictionary<column UUID, Dictionary<row UUID, String>>`).
    private static func cellText(
        col: Data, row: Data, cellDict: [Int: [ProtoValue]], objects: [Data], keyItems: [String], uuidItems: [Data]
    ) -> String? {
        guard let columns = cellDict[1] else { return nil }
        for column in columns {
            guard let cf = column.dataValue.flatMap(Protobuf.fields),
                  let key = cf.message(1), case .uuid(let colUUID)? = resolve(key, objects: objects, keyItems: keyItems, uuidItems: uuidItems),
                  colUUID == col,
                  let value = cf.message(2), case .dictionary(let rowDict)? = resolve(value, objects: objects, keyItems: keyItems, uuidItems: uuidItems),
                  let rows = rowDict[1]
            else { continue }
            for cell in rows {
                guard let rf = cell.dataValue.flatMap(Protobuf.fields),
                      let rowKey = rf.message(1), case .uuid(let rowUUID)? = resolve(rowKey, objects: objects, keyItems: keyItems, uuidItems: uuidItems),
                      rowUUID == row,
                      let rowValue = rf.message(2), case .string(let textMessage)? = resolve(rowValue, objects: objects, keyItems: keyItems, uuidItems: uuidItems)
                else { continue }
                return textMessage.string(2) ?? ""
            }
        }
        return nil
    }
}
