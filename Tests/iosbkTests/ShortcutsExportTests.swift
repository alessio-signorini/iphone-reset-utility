import Foundation
import Testing
@testable import iosbk

@Suite("ShortcutsExport")
struct ShortcutsExportTests {
    @Test("copies loose .shortcut/.wflow files and store blobs")
    func exportsShortcuts() throws {
        // A WorkflowKit Core Data store: the workflow name lives in ZSHORTCUT
        // and its serialized actions in ZSHORTCUTACTIONS.ZDATA, joined by FK.
        let workflow = try Fixture.binaryPlist(["WFWorkflowActions": [["id": "is.workflow.actions.comment"]]])
        let store = try Fixture.sqliteFile(
            domain: ShortcutsExport.domain, rel: "Shortcuts/Shortcuts.sqlite"
        ) { w in
            try w.exec("CREATE TABLE ZSHORTCUT (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZTOMBSTONED INTEGER)")
            try w.exec("INSERT INTO ZSHORTCUT (Z_PK, ZNAME, ZTOMBSTONED) VALUES (?, ?, ?)",
                       bindings: [.int(1), .text("Morning Routine"), .int(0)])
            try w.exec("CREATE TABLE ZSHORTCUTACTIONS (Z_PK INTEGER PRIMARY KEY, ZSHORTCUT INTEGER, ZDATA BLOB)")
            try w.exec("INSERT INTO ZSHORTCUTACTIONS (Z_PK, ZSHORTCUT, ZDATA) VALUES (?, ?, ?)",
                       bindings: [.int(1), .int(1), .blob(workflow)])
        }
        let backup = try Fixture.build([
            store,
            FixtureFile(domain: ShortcutsExport.domain,
                        rel: "Documents/My Shortcut.shortcut", data: Data("SIGNED-SHORTCUT".utf8)),
        ])

        let dest = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-sc-\(UUID().uuidString)")
        let result = try ShortcutsExport.run(backup: backup, to: dest)

        #expect(result.written.count == 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        // Loose file copied through verbatim.
        #expect(files.contains { $0.hasSuffix(".shortcut") && $0.contains("My") })
        // Store blob named from ZNAME.
        let named = try #require(files.first { $0.contains("Morning") })
        #expect(named.hasSuffix(".shortcut"))
        #expect(try Data(contentsOf: dest.appending(path: named)) == workflow)
    }

    @Test("writes nothing when the shortcuts domain is absent")
    func noShortcuts() throws {
        let backup = try Fixture.build([
            FixtureFile(domain: "HomeDomain", rel: "Library/Preferences/unrelated.plist"),
        ])
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-sc-\(UUID().uuidString)")
        let result = try ShortcutsExport.run(backup: backup, to: dest)
        #expect(result.written.isEmpty)
    }
}
