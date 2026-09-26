import Foundation

/// A plugin extracts a typed list of `Item`s from a backup, and optionally
/// knows how to turn those items into configuration-profile payloads,
/// curated/editable output (apps only), or restore shell commands.
///
/// Conformances only need to implement `extract`; every other requirement
/// has a no-op default so plugins that don't support a given restore channel
/// (e.g. wifi has no `curate`) don't need boilerplate.
protocol ExtractorPlugin: Sendable {
    associatedtype Item: Encodable & Sendable

    var key: String { get }
    var summary: String { get }

    /// Whether this plugin contributes payloads to `iosbk profile`'s
    /// .mobileconfig output. `apps` restores via its own curate/download/
    /// install workflow instead, so it opts out.
    var buildsProfile: Bool { get }

    func extract(_ backup: Backup, dryRun: Bool) throws -> [Item]

    /// One-line human-readable description of `item`, used by `iosbk extract`
    /// non-JSON output.
    func describe(_ item: Item) -> String

    /// Converts extracted items into configuration-profile payloads, merged
    /// by `iosbk profile` into a single `.mobileconfig`.
    func payloads(_ items: [Item]) -> [Payload]
}

extension ExtractorPlugin {
    func extract(_ backup: Backup) throws -> [Item] {
        try extract(backup, dryRun: false)
    }

    var buildsProfile: Bool { true }
    func describe(_ item: Item) -> String { "\(item)" }
    func payloads(_ items: [Item]) -> [Payload] { [] }
}

/// Type-erased wrapper over `ExtractorPlugin` so the CLI can hold a
/// heterogeneous list of plugins (`Registry.all`) without exposing each
/// plugin's associated `Item` type.
struct AnyExtractorPlugin: Sendable {
    let key: String
    let summary: String
    let buildsProfile: Bool

    private let _extract: @Sendable (Backup, Bool) throws -> [Any]
    private let _describe: @Sendable (Any) -> String
    private let _encodeJSON: @Sendable ([Any]) throws -> Data
    private let _payloads: @Sendable ([Any]) -> [Payload]

    init<P: ExtractorPlugin>(_ plugin: P) {
        self.key = plugin.key
        self.summary = plugin.summary
        self.buildsProfile = plugin.buildsProfile
        self._extract = { backup, dryRun in try plugin.extract(backup, dryRun: dryRun) }
        self._describe = { any in
            guard let item = any as? P.Item else { return String(describing: any) }
            return plugin.describe(item)
        }
        self._encodeJSON = { items in
            guard let typed = items as? [P.Item] else { return Data() }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try enc.encode(typed)
        }
        self._payloads = { items in
            guard let typed = items as? [P.Item] else { return [] }
            return plugin.payloads(typed)
        }
    }

    func extract(_ backup: Backup, dryRun: Bool = false) throws -> [Any] {
        try _extract(backup, dryRun)
    }

    func describe(_ item: Any) -> String { _describe(item) }

    func json(_ items: [Any]) throws -> Data { try _encodeJSON(items) }

    func payloads(_ items: [Any]) -> [Payload] { _payloads(items) }
}

/// Registry of every v1 plugin, looked up by CLI key (`"webclips"`, `"wifi"`,
/// `"accounts"`, `"apps"`).
enum Registry {
    static let all: [AnyExtractorPlugin] = [
        AnyExtractorPlugin(AppsPlugin()),
        AnyExtractorPlugin(WebClipsPlugin()),
        AnyExtractorPlugin(WifiPlugin()),
        AnyExtractorPlugin(AccountsPlugin()),
        AnyExtractorPlugin(CertsPlugin()),
    ]

    static subscript(key: String) -> AnyExtractorPlugin? {
        all.first { $0.key == key }
    }
}
