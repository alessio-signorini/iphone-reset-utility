import Foundation
import Testing
@testable import iosbk

@Suite("WifiPlugin")
struct WifiPluginTests {
    @Test("extracts networks from the first matching candidate path (List array + keyed dict)")
    func extractsFromFirstCandidatePath() throws {
        let backup = try Fixture.wifiBackup()
        let networks = try WifiPlugin().extract(backup, dryRun: false)
        #expect(networks.count == 2)

        let home = try #require(networks.first { $0.ssid == "HomeNet" })
        #expect(home.encryption == "WPA")
        #expect(home.hidden == false)

        let office = try #require(networks.first { $0.ssid == "OfficeNet" })
        #expect(office.encryption == "WPA2")
        #expect(office.hidden == true)
    }

    @Test("returns an empty list, not an error, when no candidate path matches")
    func returnsEmptyWhenNoCandidateMatches() throws {
        let backup = try Fixture.emptyBackup()
        let networks = try WifiPlugin().extract(backup, dryRun: false)
        #expect(networks.isEmpty)
    }

    @Test("payloads() never includes a Password key")
    func payloadsNeverIncludePassword() throws {
        let backup = try Fixture.wifiBackup()
        let plugin = WifiPlugin()
        let networks = try plugin.extract(backup, dryRun: false)
        let payloads = plugin.payloads(networks)

        let data = try ProfileBuilder.build(payloads)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        let plistUnwrapped = try #require(plist)
        let content = try #require(plistUnwrapped["PayloadContent"] as? [[String: Any]])
        for entry in content {
            #expect(entry["Password"] == nil)
            #expect(entry["PayloadType"] as? String == "com.apple.wifi.managed")
        }
    }
}
