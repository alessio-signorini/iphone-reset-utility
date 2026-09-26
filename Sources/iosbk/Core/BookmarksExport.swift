import Foundation

/// Exports Safari bookmarks from a backup's `Bookmarks.db` into a
/// Netscape-format `bookmarks.html`.
///
/// iOS has no on-device bookmark import. The intended flow is: import this
/// HTML into Safari on a Mac (File → Import From → Bookmarks HTML File) and
/// let iCloud sync the bookmarks back to the iPhone.
///
/// // VERIFY: the `bookmarks` table schema (`id`, `parent`, `type`, `title`,
/// `url`) should be confirmed against a real backup and recorded in the PR
/// under "Verified on-device".
enum BookmarksExport {
    static let domain = "HomeDomain"
    static let pathLike = "Library/Safari/Bookmarks.db"

    /// A bookmark leaf or a folder node.
    final class Node {
        let id: Int
        let parent: Int
        let title: String
        let url: String?
        var children: [Node] = []
        init(id: Int, parent: Int, title: String, url: String?) {
            self.id = id; self.parent = parent; self.title = title; self.url = url
        }
        var isFolder: Bool { url == nil || url!.isEmpty }
    }

    struct Result {
        let bookmarkCount: Int
        let outputFile: URL
    }

    @discardableResult
    static func run(backup: Backup, to output: URL, dryRun: Bool = false) throws -> Result {
        let roots = try readTree(backup: backup, dryRun: dryRun)
        let html = html(roots)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(html.utf8).write(to: output)
        return Result(bookmarkCount: countLeaves(roots), outputFile: output)
    }

    /// Reads all rows and assembles the parent/child tree, returning the
    /// top-level nodes in stable order.
    static func readTree(backup: Backup, dryRun: Bool) throws -> [Node] {
        guard let file = try backup.files(domain: domain, pathLike: pathLike).first else {
            if dryRun { log("Bookmarks.db not found in \(domain)") }
            return []
        }
        let db: Sqlite
        do { db = try backup.openSqlite(file) }
        catch {
            if dryRun { log("Bookmarks.db could not be opened: \(error)") }
            return []
        }
        guard let rows = try? db.query(
            "SELECT id, parent, title, url FROM bookmarks ORDER BY parent, id")
        else {
            if dryRun { log("bookmarks table not present in Bookmarks.db") }
            return []
        }

        var nodes: [Int: Node] = [:]
        var order: [Node] = []
        for row in rows {
            guard let id = row.int("id") else { continue }
            let node = Node(
                id: id,
                parent: row.int("parent") ?? 0,
                title: row.string("title") ?? "",
                url: row.string("url"))
            nodes[id] = node
            order.append(node)
        }

        var roots: [Node] = []
        for node in order {
            if let parent = nodes[node.parent], parent !== node {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        }
        return roots
    }

    /// Renders the Netscape bookmark file format.
    static func html(_ roots: [Node]) -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        for node in roots {
            out += render(node, indent: 1)
        }
        out += "</DL><p>\n"
        return out
    }

    private static func render(_ node: Node, indent: Int) -> String {
        let pad = String(repeating: "    ", count: indent)
        if node.isFolder {
            // A folder with no title and no children adds nothing useful.
            if node.title.isEmpty && node.children.isEmpty { return "" }
            var out = ""
            if !node.title.isEmpty {
                out += "\(pad)<DT><H3>\(ExportFormat.htmlEscape(node.title))</H3>\n"
            }
            out += "\(pad)<DL><p>\n"
            for child in node.children {
                out += render(child, indent: indent + 1)
            }
            out += "\(pad)</DL><p>\n"
            return out
        }
        let title = node.title.isEmpty ? (node.url ?? "") : node.title
        return "\(pad)<DT><A HREF=\"\(ExportFormat.htmlEscape(node.url ?? ""))\">\(ExportFormat.htmlEscape(title))</A>\n"
    }

    static func countLeaves(_ roots: [Node]) -> Int {
        var count = 0
        func walk(_ n: Node) {
            if !n.isFolder { count += 1 }
            n.children.forEach(walk)
        }
        roots.forEach(walk)
        return count
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write("bookmarks: \(message)\n".data(using: .utf8)!)
    }
}
