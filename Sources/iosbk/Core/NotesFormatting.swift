import Foundation

/// Decodes Apple Notes' rich-text model (a flat run-length-encoded list of
/// formatting spans over the note's plain text, `String.attributeRun`) and
/// renders it to Markdown.
///
/// Schema (per community reverse-engineering, e.g. dunhamsteve/notesutils —
/// there is no public spec, so this is necessarily best-effort):
/// ```
/// message String {
///     string string = 2;
///     repeated AttributeRun attributeRun = 5; // lengths sum to `string`'s UTF-16 length
/// }
/// message AttributeRun {
///     uint32 length = 1;
///     ParagraphStyle paragraphStyle = 2;
///     uint32 fontHints = 5;       // 1=bold, 2=italic, 3=bold+italic
///     uint32 underline = 6;
///     uint32 strikethrough = 7;
///     string link = 9;
///     AttachmentInfo attachmentInfo = 12;
/// }
/// message ParagraphStyle {
///     uint32 style = 1;  // 0=title, 1=heading, 4=monospace, 100=dot item,
///                        // 101=dash item, 102=numbered item, 103=checklist item
///     int32 indent = 4;
///     Todo todo = 5;
/// }
/// message Todo { bool done = 2; }
/// message AttachmentInfo { string attachmentIdentifier = 1; string typeUTI = 2; }
/// ```
enum NotesFormatting {
    struct AttachmentInfo {
        let identifier: String
        let typeUTI: String?
    }

    struct AttributeRun {
        var length: Int // UTF-16 code units
        var paragraphKind: Int?
        var indent: Int = 0
        var isChecklistItem: Bool = false
        var checklistDone: Bool = false
        var bold: Bool = false
        var italic: Bool = false
        var underline: Bool = false
        var strikethrough: Bool = false
        var link: String?
        var attachment: AttachmentInfo?

        var hasParagraphInfo: Bool { paragraphKind != nil || isChecklistItem || indent != 0 }
    }

    /// Reads the `attributeRun` field (5) of a note's `String` message.
    static func attributeRuns(_ stringMessage: [Int: [ProtoValue]]) -> [AttributeRun] {
        (stringMessage[5] ?? []).compactMap { value in
            guard let f = value.dataValue.flatMap(Protobuf.fields) else { return nil }
            var run = AttributeRun(length: Int(f.varint(1) ?? 0))
            if let ps = f.message(2) {
                run.paragraphKind = ps.varint(1).map(Int.init)
                run.indent = Int(ps.varint(4) ?? 0)
                if let todo = ps.message(5) {
                    run.isChecklistItem = true
                    run.checklistDone = (todo.varint(2) ?? 0) != 0
                }
            }
            if let hints = f.varint(5) {
                run.bold = hints == 1 || hints == 3
                run.italic = hints == 2 || hints == 3
            }
            run.underline = (f.varint(6) ?? 0) != 0
            run.strikethrough = (f.varint(7) ?? 0) != 0
            run.link = f.string(9)
            if let ai = f.message(12), let id = ai.string(1) {
                run.attachment = AttachmentInfo(identifier: id, typeUTI: ai.string(2))
            }
            return run
        }
    }

    /// Renders `text` + `runs` to Markdown. `resolveAttachment` is called for
    /// every attachment run and should return the Markdown to substitute in
    /// its place (a rendered table, an image placeholder, ...).
    static func render(text: String, runs: [AttributeRun], resolveAttachment: (AttachmentInfo) -> String) -> String {
        let utf16 = Array(text.utf16)
        // Fall back to a single unstyled run spanning the whole note so
        // plain-text notes (or any we fail to find runs for) still render.
        let runs = runs.isEmpty ? [AttributeRun(length: utf16.count)] : runs

        var output = ""
        var lineBuffer = ""
        var lineStyle: AttributeRun?
        var cursor = 0

        func flushLine() {
            var content = lineBuffer
            if lineStyle?.paragraphKind == 4, !content.isEmpty { content = "`\(content)`" } // monospace
            output += linePrefix(for: lineStyle) + content + "\n"
            lineBuffer = ""
            lineStyle = nil
        }

        for run in runs {
            let end = min(cursor + run.length, utf16.count)
            guard cursor <= end else { continue }
            let segment: String
            if let attachment = run.attachment {
                segment = resolveAttachment(attachment)
            } else {
                segment = String(decoding: utf16[cursor..<end], as: UTF16.self)
            }
            cursor = end

            if lineStyle == nil, run.hasParagraphInfo { lineStyle = run }

            var pieces = segment.components(separatedBy: "\n")
            while pieces.count > 1 {
                lineBuffer += inlineFormat(pieces.removeFirst(), run: run)
                flushLine()
            }
            lineBuffer += inlineFormat(pieces[0], run: run)
        }
        if !lineBuffer.isEmpty || lineStyle != nil { flushLine() }

        // Safety net: strip any object-replacement chars left by attachment
        // runs whose attachment info we failed to resolve.
        return output.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private static func inlineFormat(_ piece: String, run: AttributeRun) -> String {
        guard !piece.isEmpty else { return piece }
        var s = piece
        if let link = run.link { s = "[\(s)](\(link))" }
        if run.strikethrough { s = "~~\(s)~~" }
        if run.underline { s = "<u>\(s)</u>" }
        if run.bold && run.italic { s = "***\(s)***" }
        else if run.bold { s = "**\(s)**" }
        else if run.italic { s = "*\(s)*" }
        return s
    }

    private static func linePrefix(for style: AttributeRun?) -> String {
        guard let style else { return "" }
        let indent = String(repeating: "  ", count: max(0, style.indent))
        if style.isChecklistItem { return indent + (style.checklistDone ? "- [x] " : "- [ ] ") }
        switch style.paragraphKind {
        case 0: return "# "
        case 1: return "## "
        case 100, 101: return indent + "- "
        case 102: return indent + "1. "
        default: return indent
        }
    }
}
