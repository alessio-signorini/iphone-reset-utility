import Foundation
import Testing
@testable import iosbk

@Suite("BluetoothExport")
struct BluetoothExportTests {
    @Test("renders paired devices from the address-keyed plist")
    func exportsFromPlist() throws {
        let plist: [String: Any] = [
            "aa:bb:cc:dd:ee:ff": ["Name": "AirPods Pro"],
            "11:22:33:44:55:66": ["Name": "Car Audio"],
        ]
        let backup = try Fixture.build([
            FixtureFile(domain: BluetoothExport.domain,
                        rel: BluetoothExport.plistPathLike,
                        data: try Fixture.binaryPlist(plist)),
        ])
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-bt-\(UUID().uuidString)/bluetooth.txt")
        let result = try BluetoothExport.run(backup: backup, to: dest)

        #expect(result.devices.count == 2)
        let text = try String(contentsOf: dest, encoding: .utf8)
        #expect(text.contains("AirPods Pro"))
        #expect(text.contains("aa:bb:cc:dd:ee:ff"))
        #expect(text.contains("cannot be restored"))
    }

    @Test("writes a friendly message when no devices are present")
    func noDevices() throws {
        let backup = try Fixture.build([
            FixtureFile(domain: "HomeDomain", rel: "Library/Preferences/unrelated.plist"),
        ])
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "iosbk-bt-\(UUID().uuidString)/bluetooth.txt")
        let result = try BluetoothExport.run(backup: backup, to: dest)
        #expect(result.devices.isEmpty)
        let text = try String(contentsOf: dest, encoding: .utf8)
        #expect(text.contains("No paired Bluetooth devices"))
    }
}
