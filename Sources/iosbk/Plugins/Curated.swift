import Foundation

/// One item in a curated `profile.yml` section: a human-readable
/// description (the same one-liner `iosbk list`/`--dry-run` use) plus a
/// `keep` flag.
///
/// This shape is deliberately generic — one struct covers every plugin type
/// (webclips/wifi/accounts/certs) — because the curated file's only job is
/// to let a human review and de-select items. It never carries the actual
/// payload data (icons, keychain passwords, certificate bytes, ...); `iosbk
/// profile install` re-reads the backup for that, matching backup items
/// back to curated ones by description.
struct CuratedItem: Equatable {
    var description: String
    var keep: Bool
}

/// Codec + install-time filtering for `profile.yml`, the output of `iosbk
/// profile curate`: one section per plugin key, e.g.
///
/// ```yaml
/// webclips:
///   - description: "Example -> https://example.com"
///     keep: true
/// wifi:
///   - description: "HomeNet (WPA2)"
///     keep: true
/// ```
///
/// Whole-line `#` comments and deleted records are both honoured as
/// de-selection, same as `apps/list.yml`.
enum CuratedProfile {
    /// Renders one section per (plugin key, items) pair into a single file,
    /// in the order given.
    static func encode(sections: [(key: String, items: [CuratedItem])]) -> Data {
        var out = Data()
        for section in sections {
            let records = section.items.map { item in
                [("description", CurateYAML.quoted(item.description)),
                 ("keep", CurateYAML.bool(item.keep))]
            }
            out.append(CurateYAML.encode(root: section.key, records: records))
        }
        return out
    }

    /// Parses a curated file into `[pluginKey: [CuratedItem]]`.
    static func decode(_ data: Data) throws -> [String: [CuratedItem]] {
        let sections = try CurateYAML.decodeSections(data)
        var out: [String: [CuratedItem]] = [:]
        for (root, records) in sections {
            out[root] = records.compactMap { r in
                guard let description = r["description"], !description.isEmpty else { return nil }
                return CuratedItem(description: description, keep: (r["keep"] ?? "true") == "true")
            }
        }
        return out
    }

    /// The set of descriptions marked `keep: true` for `key`, or `nil` if
    /// `key` has no section at all (meaning that plugin wasn't curated —
    /// `iosbk profile install` skips it entirely rather than including
    /// everything the backup has).
    static func keptDescriptions(for key: String, in sections: [String: [CuratedItem]]) -> Set<String>? {
        guard let items = sections[key] else { return nil }
        return Set(items.filter(\.keep).map(\.description))
    }
}
