import Foundation

/// Exports the list of previously-paired Bluetooth devices from a backup into
/// a plain-text file.
///
/// Bluetooth pairings cannot be restored: re-pairing needs the physical
/// accessory and a fresh handshake (the link keys are device-specific and
/// never leave the secure element). This export is an inventory only — a
/// reminder of which devices to re-pair by hand.
///
/// // VERIFY: the Bluetooth device list lives under `SystemPreferencesDomain`
/// (`SystemConfiguration/com.apple.MobileBluetooth.devices.plist`), a
/// dictionary keyed by device address whose values carry a `Name`. Paired LE
/// devices may instead be recorded in a
/// `com.apple.MobileBluetooth.ledevices.paired*` database. Confirm both
/// against a real backup and record findings in the PR under "Verified
/// on-device".
enum BluetoothExport {
    static let domain = "SystemPreferencesDomain"
    static let plistPathLike = "SystemConfiguration/com.apple.MobileBluetooth.devices.plist"
    static let pairedDBPathLike = "%com.apple.MobileBluetooth.ledevices.paired%"

    struct Device {
        let address: String
        let name: String?
    }

    struct Result {
        let devices: [Device]
        let outputFile: URL
    }

    @discardableResult
    static func run(backup: Backup, to output: URL, dryRun: Bool = false) throws -> Result {
        var devices = readDevicesPlist(backup: backup, dryRun: dryRun)
        devices.append(contentsOf: readPairedDB(backup: backup, dryRun: dryRun))

        // De-dupe by address, keeping the first (usually named) entry.
        var seen = Set<String>()
        let unique = devices.filter { seen.insert($0.address.lowercased()).inserted }

        let text = render(unique)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: output)
        return Result(devices: unique, outputFile: output)
    }

    /// Reads the address-keyed devices plist, pulling a `Name` from each value.
    static func readDevicesPlist(backup: Backup, dryRun: Bool) -> [Device] {
        guard let file = (try? backup.files(domain: domain, pathLike: plistPathLike))?.first,
              let plist = try? backup.readPlist(file)
        else {
            if dryRun { log("devices.plist not found in \(domain)") }
            return []
        }
        var out: [Device] = []
        for (address, value) in plist {
            let dict = value as? [String: Any]
            let name = (dict?["Name"] as? String)
                ?? (dict?["name"] as? String)
                ?? (dict?["UserNameKey"] as? String)
            out.append(Device(address: address, name: name))
        }
        return out.sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
    }

    /// Best-effort read of a paired-LE-devices database: scans every table for
    /// address-like and name-like columns.
    static func readPairedDB(backup: Backup, dryRun: Bool) -> [Device] {
        guard let file = (try? backup.files(pathLike: pairedDBPathLike))?.first,
              let db = try? backup.openSqlite(file)
        else { return [] }
        let tables = (try? db.query("SELECT name FROM sqlite_master WHERE type='table'"))?
            .compactMap { $0.string("name") } ?? []
        var out: [Device] = []
        for table in tables {
            guard let rows = try? db.query("SELECT * FROM \"\(table)\"") else { continue }
            for row in rows {
                guard let address = row.string("Address") ?? row.string("address")
                        ?? row.string("Uuid") ?? row.string("uuid")
                else { continue }
                out.append(Device(address: address, name: row.string("Name") ?? row.string("name")))
            }
        }
        return out
    }

    static func render(_ devices: [Device]) -> String {
        var lines = [
            "Previously paired Bluetooth devices",
            "(These cannot be restored automatically — re-pair each device by hand.)",
            "",
        ]
        if devices.isEmpty {
            lines.append("No paired Bluetooth devices found in this backup.")
        } else {
            for d in devices {
                lines.append("\(d.name ?? "(unknown)")\t\(d.address)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write("bluetooth: \(message)\n".data(using: .utf8)!)
    }
}
