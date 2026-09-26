import Foundation
import Compression
import Testing
@testable import iosbk

@Suite("NotesExport")
struct NotesExportTests {
    /// Builds a `NoteStore.sqlite`-backed backup holding `notes`, where each
    /// entry is `(title-line + body, metadata)`. The note body is stored the
    /// way modern iOS stores it: a gzip-compressed protobuf in
    /// `ZICNOTEDATA.ZDATA`, linked to a `ZICCLOUDSYNCINGOBJECT` metadata row.
    private struct Seed {
        var text: String
        var identifier: String
        var titleColumn: String
    }

    private func backup(_ seeds: [Seed]) throws -> Backup {
        let db = try Fixture.sqliteFile(domain: NotesExport.domain, rel: "NoteStore.sqlite") { w in
            try w.exec("""
                CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                    Z_PK INTEGER PRIMARY KEY, ZTITLE1 TEXT, ZIDENTIFIER TEXT,
                    ZCREATIONDATE1 REAL, ZMODIFICATIONDATE1 REAL)
                """)
            try w.exec("""
                CREATE TABLE ZICNOTEDATA (
                    Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)
                """)
            for (i, seed) in seeds.enumerated() {
                let pk = i + 1
                try w.exec(
                    "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE1, ZIDENTIFIER, ZCREATIONDATE1, ZMODIFICATIONDATE1) VALUES (?, ?, ?, ?, ?)",
                    bindings: [.int(pk), .text(seed.titleColumn), .text(seed.identifier),
                               .int(700_000_000), .int(700_000_100)])
                try w.exec(
                    "INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES (?, ?, ?)",
                    bindings: [.int(pk), .int(pk), .blob(TestNotes.gzippedNote(text: seed.text))])
            }
        }
        return try Fixture.build([db])
    }

    private func tmpDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "iosbk-notes-\(UUID().uuidString)")
    }

    @Test("writes one Markdown file per note named after its dashed title")
    func exportsPerNoteFiles() throws {
        let backup = try backup([
            Seed(text: "Shopping List\nMilk\nEggs", identifier: "AAA", titleColumn: "Shopping List"),
            Seed(text: "Meeting Notes\nDiscuss roadmap", identifier: "BBB", titleColumn: "Meeting Notes"),
        ])
        let dest = tmpDir()
        let result = try NotesExport.run(backup: backup, to: dest)

        #expect(result.written.count == 2)
        let shopping = try String(
            contentsOf: dest.appending(path: "Shopping-List.md"), encoding: .utf8)
        #expect(shopping == "Shopping List\nMilk\nEggs\n")
        #expect(FileManager.default.fileExists(
            atPath: dest.appending(path: "Meeting-Notes.md").path))

        let index = try String(contentsOf: dest.appending(path: "index.csv"), encoding: .utf8)
        #expect(index.contains("file,identifier,title,created,modified"))
        #expect(index.contains("Shopping-List.md"))
        #expect(index.contains("AAA"))
    }

    @Test("titles a note from its first non-empty line")
    func titleFromFirstNonEmptyLine() throws {
        // Leading newline: the first *non-empty* line is the title, matching
        // how the Notes app itself titles a note.
        let backup = try backup([
            Seed(text: "\nStandalone Body", identifier: "note-xyz", titleColumn: ""),
        ])
        let dest = tmpDir()
        let result = try NotesExport.run(backup: backup, to: dest)
        #expect(result.written == ["Standalone-Body.md"])
        let body = try String(
            contentsOf: dest.appending(path: "Standalone-Body.md"), encoding: .utf8)
        #expect(body == "\nStandalone Body\n")
    }

    @Test("falls back to the identifier when the title has no file-name-safe characters")
    func identifierFallback() throws {
        // A title of only path separators slugs to nothing, so the note's
        // identifier is used for the file name instead.
        let backup = try backup([
            Seed(text: "///\nbody", identifier: "note-xyz", titleColumn: ""),
        ])
        let dest = tmpDir()
        let result = try NotesExport.run(backup: backup, to: dest)
        #expect(result.written == ["note-xyz.md"])
    }

    @Test("disambiguates notes that share a title")
    func dedupesDuplicateTitles() throws {
        let backup = try backup([
            Seed(text: "Ideas\none", identifier: "A", titleColumn: "Ideas"),
            Seed(text: "Ideas\ntwo", identifier: "B", titleColumn: "Ideas"),
        ])
        let dest = tmpDir()
        let result = try NotesExport.run(backup: backup, to: dest)
        #expect(Set(result.written) == ["Ideas.md", "Ideas-2.md"])
    }

    @Test("no store yields an empty export with just the index header")
    func missingStore() throws {
        let backup = try Fixture.build([
            FixtureFile(domain: "HomeDomain", rel: "Library/Other/x", data: Data("x".utf8)),
        ])
        let dest = tmpDir()
        let result = try NotesExport.run(backup: backup, to: dest)
        #expect(result.written.isEmpty)
        let index = try String(contentsOf: dest.appending(path: "index.csv"), encoding: .utf8)
        #expect(index == "file,identifier,title,created,modified\n")
    }

    @Test("Gzip.inflate round-trips a gzip stream")
    func gzipRoundTrip() throws {
        let original = Data("hello notes \u{1F4DD}".utf8)
        let inflated = Gzip.inflate(TestNotes.gzip(original))
        #expect(inflated == original)
    }

    @Test("renders bold/italic, checklists, and bullet lists as Markdown")
    func richFormattingRendersToMarkdown() throws {
        // "My Title\n" (title style) + "bold" (bold) + " and " (plain) +
        // "italic\n" (italic) + "check me\n" (checked-off checklist item) +
        // "bullet item\n" (dot-list item).
        let text = "My Title\nbold and italic\ncheck me\nbullet item\n"
        let runs: [[UInt8]] = [
            TestNotes.attributeRun(length: "My Title\n".utf16.count, paragraphStyle: 0),
            TestNotes.attributeRun(length: "bold".utf16.count, bold: true),
            TestNotes.attributeRun(length: " and ".utf16.count),
            TestNotes.attributeRun(length: "italic\n".utf16.count, italic: true),
            TestNotes.attributeRun(length: "check me\n".utf16.count, todoDone: true),
            TestNotes.attributeRun(length: "bullet item\n".utf16.count, paragraphStyle: 100),
        ]
        let backup = try Fixture.build([
            try Fixture.sqliteFile(domain: NotesExport.domain, rel: "NoteStore.sqlite") { w in
                try w.exec("""
                    CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT)
                    """)
                try w.exec("CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)")
                try w.exec("INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER) VALUES (1, 'AAA')")
                try w.exec(
                    "INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES (1, 1, ?)",
                    bindings: [.blob(TestNotes.gzippedNote(text: text, runs: runs))])
            },
        ])
        let dest = tmpDir()
        let result = try NotesExport.run(backup: backup, to: dest)
        #expect(result.written == ["My-Title.md"])
        let body = try String(contentsOf: dest.appending(path: "My-Title.md"), encoding: .utf8)
        #expect(body == "# My Title\n**bold** and *italic*\n- [x] check me\n- bullet item\n")
    }

    @Test("resolves a table attachment reference into a Markdown table")
    func tableAttachmentRendersAsMarkdownTable() throws {
        let text = "Notes\n\u{FFFC}\n"
        let runs: [[UInt8]] = [
            TestNotes.attributeRun(length: "Notes\n".utf16.count),
            TestNotes.attributeRun(
                length: "\u{FFFC}".utf16.count,
                attachmentIdentifier: "TABLE-1", attachmentTypeUTI: "com.apple.notes.table"),
            TestNotes.attributeRun(length: "\n".utf16.count),
        ]
        let backup = try Fixture.build([
            try Fixture.sqliteFile(domain: NotesExport.domain, rel: "NoteStore.sqlite") { w in
                try w.exec("""
                    CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                        Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZMERGEABLEDATA1 BLOB)
                    """)
                try w.exec("CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)")
                try w.exec(
                    "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZMERGEABLEDATA1) VALUES (1, 'NOTE-1', NULL)")
                try w.exec(
                    "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZMERGEABLEDATA1) VALUES (2, 'TABLE-1', ?)",
                    bindings: [.blob(TestTable.sampleTableProto())])
                try w.exec(
                    "INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES (1, 1, ?)",
                    bindings: [.blob(TestNotes.gzippedNote(text: text, runs: runs))])
            },
        ])
        let dest = tmpDir()
        let result = try NotesExport.run(backup: backup, to: dest)
        #expect(result.written == ["Notes.md"])
        let body = try String(contentsOf: dest.appending(path: "Notes.md"), encoding: .utf8)
        #expect(body.contains("| A1 | B1 |"))
        #expect(body.contains("| A2 | B2 |"))
    }
}

@Suite("NotesTable")
struct NotesTableTests {
    @Test("decodes a 2x2 table's cell text in row/column order")
    func decodesSimpleTable() throws {
        let rows = NotesTable.decode(TestTable.sampleTableProto())
        #expect(rows == [["A1", "B1"], ["A2", "B2"]])
    }

    @Test("renders a decoded grid as a Markdown table")
    func rendersMarkdownTable() throws {
        let markdown = NotesTable.markdown([["A1", "B1"], ["A2", "B2"]])
        #expect(markdown == "| A1 | B1 |\n| --- | --- |\n| A2 | B2 |")
    }

    @Test("returns nil for data that isn't a recognizable table")
    func rejectsGarbage() throws {
        #expect(NotesTable.decode(Data("not a table".utf8)) == nil)
    }
}

/// Builds a minimal 2-row/2-column table matching Apple Notes' embedded-table
/// CRDT format, for exercising `NotesTable` without live device data.
enum TestTable {
    static func sampleTableProto() -> Data {
        let row1 = Data([0x01]), row2 = Data([0x02]), col1 = Data([0x03]), col2 = Data([0x04])
        let keyItems = ["crRows", "crColumns", "cellColumns", "UUIDIndex"]

        func objectIDIndex(_ n: Int) -> [UInt8] { TestNotes.varintField(6, n) }
        func objectIDValue(_ n: Int) -> [UInt8] { TestNotes.varintField(2, n) }
        func mapEntry(key: Int, value: [UInt8]) -> [UInt8] {
            TestNotes.varintField(1, key) + TestNotes.lenField(2, value)
        }
        func customObject(_ entries: [[UInt8]]) -> [UInt8] {
            entries.reduce(into: [UInt8]()) { $0 += TestNotes.lenField(3, $1) }
        }
        func dictElement(key: [UInt8], value: [UInt8]) -> [UInt8] {
            TestNotes.lenField(1, key) + TestNotes.lenField(2, value)
        }
        func dictionary(_ elements: [[UInt8]]) -> [UInt8] {
            elements.reduce(into: [UInt8]()) { $0 += TestNotes.lenField(1, $1) }
        }
        func arrayAttachment(index: Int, uuid: Data) -> [UInt8] {
            TestNotes.varintField(1, index) + TestNotes.lenField(2, [UInt8](uuid))
        }
        func orderedSet(uuids: [(Int, Data)]) -> [UInt8] {
            let ttArray = uuids.reduce(into: [UInt8]()) { $0 += TestNotes.lenField(2, arrayAttachment(index: $1.0, uuid: $1.1)) }
            let array = TestNotes.lenField(1, ttArray) // Array.array = 1
            return TestNotes.lenField(1, array) // OrderedSet.ordering = 1
        }
        func uuidWrapper(uuidIndex: Int) -> [UInt8] {
            customObject([mapEntry(key: 3, value: objectIDValue(uuidIndex))]) // "UUIDIndex"
        }
        func docObject(custom: [UInt8]? = nil, dictionary dict: [UInt8]? = nil,
                       string: [UInt8]? = nil, orderedSet os: [UInt8]? = nil) -> [UInt8] {
            var body: [UInt8] = []
            if let custom { body += TestNotes.lenField(13, custom) }
            if let dict { body += TestNotes.lenField(6, dict) }
            if let string { body += TestNotes.lenField(10, string) }
            if let os { body += TestNotes.lenField(16, os) }
            return body
        }
        func stringMessage(_ text: String) -> [UInt8] { TestNotes.lenField(2, Array(text.utf8)) }

        let rowsOrderedSet = orderedSet(uuids: [(0, row1), (1, row2)])
        let colsOrderedSet = orderedSet(uuids: [(0, col1), (1, col2)])
        // objectIndex 4/5/6/7 = row1/row2/col1/col2 UUID wrappers (see below);
        // 8/9 = per-column row dictionaries; 10-13 = cell text strings.
        let rowDictCol1 = dictionary([
            dictElement(key: objectIDIndex(4), value: objectIDIndex(10)),
            dictElement(key: objectIDIndex(5), value: objectIDIndex(11)),
        ])
        let rowDictCol2 = dictionary([
            dictElement(key: objectIDIndex(4), value: objectIDIndex(12)),
            dictElement(key: objectIDIndex(5), value: objectIDIndex(13)),
        ])
        let cellColumns = dictionary([
            dictElement(key: objectIDIndex(6), value: objectIDIndex(8)),
            dictElement(key: objectIDIndex(7), value: objectIDIndex(9)),
        ])
        let root = customObject([
            mapEntry(key: 0, value: objectIDIndex(1)), // crRows
            mapEntry(key: 1, value: objectIDIndex(2)), // crColumns
            mapEntry(key: 2, value: objectIDIndex(3)), // cellColumns
        ])

        let objects: [[UInt8]] = [
            docObject(custom: root),                 // 0
            docObject(orderedSet: rowsOrderedSet),    // 1
            docObject(orderedSet: colsOrderedSet),    // 2
            docObject(dictionary: cellColumns),       // 3
            docObject(custom: uuidWrapper(uuidIndex: 0)), // 4: row1
            docObject(custom: uuidWrapper(uuidIndex: 1)), // 5: row2
            docObject(custom: uuidWrapper(uuidIndex: 2)), // 6: col1
            docObject(custom: uuidWrapper(uuidIndex: 3)), // 7: col2
            docObject(dictionary: rowDictCol1),       // 8
            docObject(dictionary: rowDictCol2),       // 9
            docObject(string: stringMessage("A1")),   // 10
            docObject(string: stringMessage("A2")),   // 11
            docObject(string: stringMessage("B1")),   // 12
            docObject(string: stringMessage("B2")),   // 13
        ]

        var body: [UInt8] = []
        for o in objects { body += TestNotes.lenField(3, o) }
        for k in keyItems { body += TestNotes.lenField(4, Array(k.utf8)) }
        for u in [row1, row2, col1, col2] { body += TestNotes.lenField(6, [UInt8](u)) }

        let versionData = TestNotes.lenField(3, body) // Version.data = 3
        let document = TestNotes.lenField(2, versionData) // Document.version = 2
        return TestNotes.gzip(Data(document))
    }
}

/// Test-only builders for the gzip + protobuf shape that iOS stores note
/// bodies in, so the fixtures exercise the real `Gzip` / protobuf reader.
enum TestNotes {
    /// A gzip member wrapping raw DEFLATE (RFC 1951) produced by `Compression`.
    /// The CRC-32 trailer is left zero — `Gzip.inflate` does not verify it.
    static func gzip(_ data: Data) -> Data {
        let src = [UInt8](data)
        let cap = src.count + 4096
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = src.withUnsafeBufferPointer { s in
            compression_encode_buffer(dst, cap, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
        }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff]) // header
        out.append(dst, count: n)
        out.append(contentsOf: [0, 0, 0, 0]) // CRC-32 (unverified)
        let isize = UInt32(truncatingIfNeeded: src.count)
        out.append(contentsOf: [
            UInt8(isize & 0xff), UInt8((isize >> 8) & 0xff),
            UInt8((isize >> 16) & 0xff), UInt8((isize >> 24) & 0xff),
        ])
        return out
    }

    /// A gzipped `NoteStoreProto` whose `note_text` is `text`, matching
    /// `document (2) -> note (3) -> note_text (2)`, optionally with
    /// `attributeRun` (field 5) entries describing formatting/attachments.
    static func gzippedNote(text: String, runs: [[UInt8]] = []) -> Data {
        var stringMessage = lenField(2, [UInt8](text.utf8))
        for run in runs { stringMessage += lenField(5, run) }
        let note = lenField(3, stringMessage)
        let document = lenField(2, note)
        return gzip(Data(document))
    }

    /// Builds an `AttributeRun` message (`length=1, paragraphStyle=2,
    /// fontHints=5, underline=6, strikethrough=7, link=9, attachmentInfo=12`).
    static func attributeRun(
        length: Int, paragraphStyle: Int? = nil, todoDone: Bool? = nil,
        bold: Bool = false, italic: Bool = false, underline: Bool = false, strikethrough: Bool = false,
        link: String? = nil, attachmentIdentifier: String? = nil, attachmentTypeUTI: String? = nil
    ) -> [UInt8] {
        var body = varintField(1, length)
        if paragraphStyle != nil || todoDone != nil {
            var style: [UInt8] = []
            if let paragraphStyle { style += varintField(1, paragraphStyle) }
            if let todoDone { style += lenField(5, varintField(2, todoDone ? 1 : 0)) }
            body += lenField(2, style)
        }
        let hints = (bold ? 1 : 0) | (italic ? 2 : 0)
        if hints != 0 { body += varintField(5, hints) }
        if underline { body += varintField(6, 1) }
        if strikethrough { body += varintField(7, 1) }
        if let link { body += lenField(9, [UInt8](link.utf8)) }
        if attachmentIdentifier != nil || attachmentTypeUTI != nil {
            var info: [UInt8] = []
            if let attachmentIdentifier { info += lenField(1, [UInt8](attachmentIdentifier.utf8)) }
            if let attachmentTypeUTI { info += lenField(2, [UInt8](attachmentTypeUTI.utf8)) }
            body += lenField(12, info)
        }
        return body
    }

    static func lenField(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        varintBytes((field << 3) | 2) + varintBytes(payload.count) + payload
    }

    static func varintField(_ field: Int, _ value: Int) -> [UInt8] {
        varintBytes((field << 3) | 0) + varintBytes(value)
    }

    static func varintBytes(_ value: Int) -> [UInt8] {
        var x = UInt(value)
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(x & 0x7f)
            x >>= 7
            if x != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while x != 0
        return bytes
    }
}
