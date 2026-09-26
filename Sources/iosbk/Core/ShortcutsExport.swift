import Foundation

/// Exports Shortcuts from a backup into individual `.shortcut` files so they
/// can be re-added on-device.
///
/// **Verified on-device finding:** a local (Finder/iTunes-style) backup
/// *does* contain full shortcut definitions — they live in the WorkflowKit
/// Core Data store at `HomeDomain/Library/Shortcuts/Shortcuts.sqlite`, not
/// under any of the `*.shortcuts` app-group domains (those hold only
/// ephemeral state: `SavedShortcutStates/*`, the `.tips` cache, preferences).
/// Each shortcut is stored decomposed: `ZSHORTCUT` has the name/icon/metadata
/// and `ZSHORTCUTACTIONS.ZDATA` has the serialized actions. This exporter
/// reconstructs an importable `WFWorkflow` plist per shortcut from those
/// tables.
///
/// The recovered `.shortcut` files are **unsigned**. iOS only signs a
/// shortcut server-side at the moment you *share* it (producing an `AEA1`
/// archive), and that signed form is never persisted on-device or in a
/// backup — so restoring "signed as-is" is not possible from any backup.
/// Unsigned files import fine via Settings → Shortcuts → Advanced →
/// "Allow Untrusted Shortcuts".
enum ShortcutsExport {
    static let domain = "AppDomainGroup-group.com.apple.shortcuts"

    /// Where Shortcuts data has been observed across iOS versions. The
    /// authoritative modern location is the WorkflowKit Core Data store at
    /// `HomeDomain/Library/Shortcuts/Shortcuts.sqlite` (verified on a real
    /// backup); the app-group domains are kept for older layouts and loose
    /// `.shortcut`/`.wflow` files. Each target is a `(domain, pathLike)`
    /// pair; `pathLike` uses SQL `LIKE` (`%` wildcard), or nil for the
    /// whole domain.
    static let targets: [(domain: String, pathLike: String?)] = [
        ("HomeDomain", "Library/Shortcuts/%"),
        ("AppDomainGroup-group.com.apple.shortcuts", nil),
        ("AppDomain-com.apple.shortcuts", nil),
        ("AppDomainGroup-group.is.workflow.shortcuts", nil),
    ]

    struct Result {
        let written: [String] // output file names
    }

    /// All files across every `targets` location, de-duplicated by fileID.
    private static func shortcutFiles(in backup: Backup) -> [BackupFile] {
        var seen: Set<String> = []
        var out: [BackupFile] = []
        for t in targets {
            let files = (try? backup.files(domain: t.domain, pathLike: t.pathLike)) ?? []
            for f in files where seen.insert(f.id).inserted { out.append(f) }
        }
        return out
    }

    @discardableResult
    static func run(backup: Backup, to dest: URL, dryRun: Bool = false) throws -> Result {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var written: [String] = []
        var usedNames: Set<String> = []

        let files = shortcutFiles(in: backup)
        if dryRun {
            if files.isEmpty {
                log("no files under any known Shortcuts location in this backup")
            } else {
                let listing = files.map { "\($0.domain): \($0.rel)" }.joined(separator: "\n  ")
                log("candidate files (\(files.count)):\n  \(listing)")
            }
        }

        // 1) Loose shortcut/workflow definition files stored unpacked.
        for f in files where f.rel.hasSuffix(".shortcut") || f.rel.hasSuffix(".wflow") {
            guard let data = try? backup.readData(f) else { continue }
            let name = uniqueName(sanitize((f.rel as NSString).lastPathComponent), in: &usedNames)
            try data.write(to: dest.appending(path: name))
            written.append(name)
        }

        // 2) Shortcut definitions embedded as plist blobs in a Core Data store.
        for f in files where f.rel.lowercased().hasSuffix(".sqlite") {
            guard let db = try? backup.openSqlite(f) else { continue }
            written.append(contentsOf: extractFromStore(db, to: dest, usedNames: &usedNames))
        }

        if written.isEmpty {
            // Nothing recovered: the Core Data schema may differ from what's
            // assumed here (see the VERIFY note above). Surface enough to
            // diagnose which, without requiring the user to inspect
            // Manifest.db by hand.
            log("no shortcut definitions recovered (\(files.count) candidate file(s) seen)")
            if let candidates = try? backup.domains(matching: "shortcut"), !candidates.isEmpty {
                log("domains in this backup containing \"shortcut\": \(candidates.joined(separator: ", "))")
            }
            if !files.isEmpty {
                let sample = files.prefix(30).map { "\($0.domain): \($0.rel)" }.joined(separator: "\n  ")
                log("files seen:\n  \(sample)")
            }
        }
        return Result(written: written)
    }

    /// Reconstructs unsigned `.shortcut` files from a WorkflowKit Core Data
    /// store (`HomeDomain/Library/Shortcuts/Shortcuts.sqlite`).
    ///
    /// The workflow lives decomposed across the store: `ZSHORTCUT` holds one
    /// row per shortcut (name, icon relationship, input/output classes, …)
    /// and `ZSHORTCUTACTIONS.ZDATA` holds that shortcut's serialized actions
    /// (a binary plist). On modern iOS `ZDATA` is the actions array; older
    /// stores put the whole `WFWorkflow` dict there — both are handled. Only
    /// this exact schema is touched, so unrelated Core Data stores in the
    /// same directory (e.g. the giant `ToolKit/Tools-prod*.sqlite` action
    /// catalog) are ignored rather than dumped as junk.
    ///
    /// Recovered files are **unsigned**: iOS only ever signs a shortcut
    /// server-side when you share it (the signature is never stored on-device
    /// or in a backup), so these import via Settings → Shortcuts → Advanced →
    /// "Allow Untrusted Shortcuts".
    private static func extractFromStore(
        _ db: Sqlite, to dest: URL, usedNames: inout Set<String>
    ) -> [String] {
        let tables = Set((try? db.query("SELECT name FROM sqlite_master WHERE type='table'"))?
            .compactMap { $0.string("name") } ?? [])
        guard tables.contains("ZSHORTCUT"), tables.contains("ZSHORTCUTACTIONS") else {
            return [] // not a shortcut-definition store; leave it alone
        }
        let hasIcons = tables.contains("ZSHORTCUTICON")
        guard let rows = try? db.query(
            "SELECT s.*, a.ZDATA AS __actions FROM ZSHORTCUT s "
            + "JOIN ZSHORTCUTACTIONS a ON a.ZSHORTCUT = s.Z_PK") else { return [] }

        var written: [String] = []
        for row in rows {
            if let tombstoned = row.int("ZTOMBSTONED"), tombstoned != 0 { continue }
            guard let actions = row.data("__actions") else { continue }
            let icon = hasIcons ? iconInfo(pk: row.int("Z_PK"), db: db) : nil
            let plist = buildWorkflowPlist(actions: actions, row: row, icon: icon) ?? actions
            let base = sanitize(row.string("ZNAME") ?? "shortcut") + ".shortcut"
            let name = uniqueName(base, in: &usedNames)
            if (try? plist.write(to: dest.appending(path: name))) != nil {
                written.append(name)
            }
        }
        return written
    }

    /// `(startColor, glyphNumber)` for the shortcut whose primary key is
    /// `pk`, from the `ZSHORTCUTICON` table, or nil if absent.
    private static func iconInfo(pk: Int?, db: Sqlite) -> (color: Int?, glyph: Int?)? {
        guard let pk else { return nil }
        let rows = (try? db.query(
            "SELECT ZBACKGROUNDCOLORVALUE AS c, ZGLYPHNUMBER AS g "
            + "FROM ZSHORTCUTICON WHERE ZWORKFLOW = \(pk)")) ?? []
        guard let r = rows.first else { return nil }
        return (r.int("c"), r.int("g"))
    }

    /// Builds an importable `WFWorkflow` binary plist from a shortcut's
    /// serialized actions plus the sibling columns of its `ZSHORTCUT` row.
    /// If `actions` is already a complete workflow dict it's returned
    /// verbatim (perfect fidelity); otherwise it's treated as the actions
    /// array and wrapped with the icon, input classes, import questions and
    /// client-version metadata recovered from the row.
    private static func buildWorkflowPlist(
        actions actionsData: Data, row: Sqlite.Row, icon: (color: Int?, glyph: Int?)?
    ) -> Data? {
        let obj = try? PropertyListSerialization.propertyList(
            from: actionsData, options: [], format: nil)
        if let dict = obj as? [String: Any], dict["WFWorkflowActions"] != nil {
            return actionsData // already a full workflow
        }

        var wf: [String: Any] = ["WFWorkflowActions": (obj as? [Any]) ?? []]

        if let inData = row.data("ZINPUTCLASSESDATA"),
           let inObj = try? PropertyListSerialization.propertyList(from: inData, options: [], format: nil) {
            wf["WFWorkflowInputContentItemClasses"] = inObj
        }
        if let impData = row.data("ZIMPORTQUESTIONSDATA"),
           let impObj = try? PropertyListSerialization.propertyList(from: impData, options: [], format: nil) {
            wf["WFWorkflowImportQuestions"] = impObj
        } else {
            wf["WFWorkflowImportQuestions"] = []
        }
        if let icon {
            var iconDict: [String: Any] = [:]
            if let color = icon.color { iconDict["WFWorkflowIconStartColor"] = color }
            if let glyph = icon.glyph { iconDict["WFWorkflowIconGlyphNumber"] = glyph }
            if !iconDict.isEmpty { wf["WFWorkflowIcon"] = iconDict }
        }
        if let clientVersion = row.string("ZLASTMIGRATEDCLIENTVERSION") {
            wf["WFWorkflowClientVersion"] = clientVersion
        }
        if let minVersion = row.string("ZMINIMUMCLIENTVERSION") {
            wf["WFWorkflowMinimumClientVersionString"] = minVersion
            if let n = Int(minVersion) { wf["WFWorkflowMinimumClientVersion"] = n }
        }
        return try? PropertyListSerialization.data(fromPropertyList: wf, format: .binary, options: 0)
    }

    /// The shortcut names recoverable from this backup, unsanitized (as
    /// opposed to the sanitized file names `run()` writes to disk). Used to
    /// tell whether a `shortcuts://` web clip's target still exists in the
    /// backup, so `iosbk profile curate` can flag ones that can't be
    /// restored.
    static func availableNames(in backup: Backup) -> Set<String> {
        var names: Set<String> = []
        let files = shortcutFiles(in: backup)

        for f in files where f.rel.hasSuffix(".shortcut") || f.rel.hasSuffix(".wflow") {
            let stem = ((f.rel as NSString).lastPathComponent as NSString).deletingPathExtension
            if !stem.isEmpty { names.insert(stem) }
        }

        for f in files where f.rel.lowercased().hasSuffix(".sqlite") {
            guard let db = try? backup.openSqlite(f) else { continue }
            let tables = Set((try? db.query("SELECT name FROM sqlite_master WHERE type='table'"))?
                .compactMap { $0.string("name") } ?? [])
            guard tables.contains("ZSHORTCUT") else { continue }
            let rows = (try? db.query(
                "SELECT ZNAME AS name, ZTOMBSTONED AS tombstoned FROM ZSHORTCUT "
                + "WHERE ZNAME IS NOT NULL")) ?? []
            for row in rows {
                if let tombstoned = row.int("tombstoned"), tombstoned != 0 { continue }
                if let name = row.string("name"), !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }

    private static func sanitize(_ name: String) -> String {
        let base = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
        return base.isEmpty ? "shortcut" : base
    }

    /// Returns `name`, or `name-2`, `name-3`, … so no output file is overwritten.
    private static func uniqueName(_ name: String, in used: inout Set<String>) -> String {
        if used.insert(name).inserted { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if used.insert(candidate).inserted { return candidate }
            n += 1
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write("shortcuts: \(message)\n".data(using: .utf8)!)
    }
}
