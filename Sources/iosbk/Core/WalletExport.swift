import Foundation

/// Packs Wallet passes out of a backup into ready-to-AirDrop `.pkpass` files.
///
/// In the backup each pass is stored *unpacked*: a `…/<UUID>.pkpass/`
/// directory of loose files (`pass.json`, images, `manifest.json`,
/// `signature`). Wallet only accepts a pass as a single zip archive with
/// those files at its root, so this service regroups each bundle's files,
/// decrypts them, names the bundle from its `pass.json`, and zips it into one
/// recognisable `.pkpass` written directly into the output directory.
enum WalletExport {
    /// Where Wallet stores passes inside a backup.
    static let domain = "HomeDomain"
    static let pathLike = "Library/Passes/%"

    struct Result {
        /// Names of the `.pkpass` files written, in output order.
        let written: [String]
        /// Count of `.pkpass` bundles skipped (no `pass.json`).
        let skipped: Int
    }

    /// Packs every pass bundle in `backup` into `dest`. Returns which files
    /// were written so the caller can list them for the user to pick from.
    @discardableResult
    static func run(backup: Backup, to dest: URL) throws -> Result {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let bundles = group(try backup.files(domain: domain, pathLike: pathLike))

        var written: [String] = []
        var skipped = 0
        for bundleRel in bundles.keys.sorted() {
            if let name = try pack(bundleRel: bundleRel, members: bundles[bundleRel]!,
                                   backup: backup, dest: dest) {
                written.append(name)
            } else {
                skipped += 1
            }
        }
        return Result(written: written, skipped: skipped)
    }

    /// Returns the number of distinct `.pkpass` bundles present in `backup`,
    /// without writing any files (used by `iosbk list`).
    static func countBundles(backup: Backup) throws -> Int {
        let files = try backup.files(domain: domain, pathLike: pathLike)
        return group(files).count
    }

    /// Groups member files by their `…/<name>.pkpass` bundle prefix. Files
    /// outside a `.pkpass` bundle (e.g. `Cards.sqlite`) are ignored.
    private static func group(_ files: [BackupFile]) -> [String: [BackupFile]] {
        var out: [String: [BackupFile]] = [:]
        for f in files {
            guard let r = f.rel.range(of: ".pkpass/") else { continue }
            let bundle = String(f.rel[..<r.lowerBound]) + ".pkpass"
            out[bundle, default: []].append(f)
        }
        return out
    }

    /// Stages one bundle's files into a temp dir (flattened to the bundle
    /// root), then zips them into a single `.pkpass`. Returns the written file
    /// name, or nil when the bundle has no `pass.json` (not a valid pass).
    private static func pack(bundleRel: String, members: [BackupFile],
                             backup: Backup, dest: URL) throws -> String? {
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-pkpass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let prefix = bundleRel + "/"
        let stagingRoot = staging.standardizedFileURL.path
        for f in members {
            guard f.rel.hasPrefix(prefix) else { continue }
            let inner = String(f.rel.dropFirst(prefix.count))
            guard !inner.isEmpty else { continue }
            let out = staging.appending(path: inner).standardizedFileURL
            guard out.path.hasPrefix(stagingRoot + "/") else { continue } // reject traversal
            try FileManager.default.createDirectory(
                at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try backup.readData(f).write(to: out)
        }

        let passJSON = staging.appending(path: "pass.json")
        guard FileManager.default.fileExists(atPath: passJSON.path) else { return nil }

        let base = name(fromPassJSON: passJSON, fallback: (bundleRel as NSString).lastPathComponent)
        let outFile = uniqueURL(in: dest, base: base, ext: "pkpass")
        try Zip.create(contentsOf: staging, to: outFile)
        return outFile.lastPathComponent
    }

    /// Derives a human-recognisable name from a pass's `pass.json`
    /// (`organizationName` + `description`), falling back to the bundle id.
    private static func name(fromPassJSON url: URL, fallback: String) -> String {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return sanitize(fallback) }
        let parts = [json["organizationName"] as? String, json["description"] as? String]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return sanitize(parts.isEmpty ? fallback : parts.joined(separator: " - "))
    }

    /// Makes a string safe for a filename: strips path separators and control
    /// characters, collapses whitespace, and caps the length.
    private static func sanitize(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar.properties.isDefaultIgnorableCodePoint
                || scalar.value < 0x20 { return "_" }
            return Character(scalar)
        }
        let collapsed = String(cleaned).components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let trimmed = String(collapsed.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        return trimmed.isEmpty ? "pass" : trimmed
    }

    /// `<dest>/<base>.<ext>`, appending ` (2)`, ` (3)`, … on collision.
    private static func uniqueURL(in dest: URL, base: String, ext: String) -> URL {
        var candidate = dest.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dest.appending(path: "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// Minimal wrapper over the system `zip` tool.
enum Zip {
    enum ZipError: Error, CustomStringConvertible {
        case failed(Int32, String)
        var description: String {
            switch self {
            case let .failed(code, msg):
                return "zip failed (exit \(code))\(msg.isEmpty ? "" : ": \(msg)")"
            }
        }
    }

    /// Creates `dest` as a zip archive of the *contents* of `dir` (entries at
    /// the archive root, not nested under `dir`'s name).
    static func create(contentsOf dir: URL, to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = dir
        process.arguments = ["-r", "-X", "-q", dest.path, "."]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ZipError.failed(process.terminationStatus, msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
