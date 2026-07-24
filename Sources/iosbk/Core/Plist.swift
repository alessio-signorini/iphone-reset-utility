import Foundation

/// Helpers for reading the binary or XML property lists stored inside an
/// iOS backup (e.g. per-webclip `Info.plist`, `Manifest.plist`, wifi/known
/// network plists).
enum Plist {
    enum PlistError: Error {
        case invalidData
        case notADictionary
    }

    /// Parses `data` as either a binary or XML plist and returns it as
    /// `[String: Any]`. Throws `.notADictionary` if the root object isn't a
    /// dictionary (some backup plists are arrays; callers that expect those
    /// should use `readAny` instead).
    static func read(_ data: Data) throws -> [String: Any] {
        let any = try readAny(data)
        guard let dict = any as? [String: Any] else {
            throw PlistError.notADictionary
        }
        return dict
    }

    /// Parses `data` as either a binary or XML plist and returns the raw
    /// root object (dictionary, array, or scalar).
    static func readAny(_ data: Data) throws -> Any {
        var format = PropertyListSerialization.PropertyListFormat.binary
        do {
            return try PropertyListSerialization.propertyList(
                from: data, options: [], format: &format)
        } catch {
            throw PlistError.invalidData
        }
    }
}
