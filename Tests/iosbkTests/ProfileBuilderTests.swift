import Foundation
import Testing
@testable import iosbk

@Suite("ProfileBuilder")
struct ProfileBuilderTests {
    @Test("merges heterogeneous payloads into one profile that re-parses with the expected count")
    func mergesHeterogeneousPayloads() throws {
        let webClip = Payload.webClip(WebClipPayload(
            PayloadIdentifier: "com.local.iosbk.webclip.1",
            PayloadUUID: "11111111-1111-1111-1111-111111111111",
            PayloadDisplayName: "Example",
            URL: "https://example.com",
            Label: "Example",
            FullScreen: true,
            Icon: Data([0xDE, 0xAD, 0xBE, 0xEF])))

        let wifi = Payload.wifi(WifiPayload(
            PayloadIdentifier: "com.local.iosbk.wifi.1",
            PayloadUUID: "22222222-2222-2222-2222-222222222222",
            PayloadDisplayName: "HomeNet",
            SSID_STR: "HomeNet",
            EncryptionType: "WPA",
            HIDDEN_NETWORK: false))

        let data = try ProfileBuilder.build([webClip, wifi], displayName: "Test Profile")

        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        let plistUnwrapped = try #require(plist)

        #expect(plistUnwrapped["PayloadType"] as? String == "Configuration")
        #expect(plistUnwrapped["PayloadDisplayName"] as? String == "Test Profile")
        let content = try #require(plistUnwrapped["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 2)

        let webClipDict = try #require(content.first { $0["PayloadType"] as? String == "com.apple.webClip.managed" })
        #expect(webClipDict["URL"] as? String == "https://example.com")
        #expect(webClipDict["Icon"] as? Data == Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let wifiDict = try #require(content.first { $0["PayloadType"] as? String == "com.apple.wifi.managed" })
        #expect(wifiDict["SSID_STR"] as? String == "HomeNet")
        #expect(wifiDict["Password"] == nil) // v1: never emits a password key
    }

    @Test("omits the Icon key entirely when nil")
    func omitsNilIconKey() throws {
        let webClip = Payload.webClip(WebClipPayload(
            PayloadIdentifier: "com.local.iosbk.webclip.2",
            PayloadUUID: "33333333-3333-3333-3333-333333333333",
            PayloadDisplayName: "No Icon",
            URL: "https://noicon.org",
            Label: "No Icon",
            FullScreen: false,
            Icon: nil))

        let data = try ProfileBuilder.build([webClip])
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        let plistUnwrapped = try #require(plist)
        let content = try #require(plistUnwrapped["PayloadContent"] as? [[String: Any]])
        #expect(content.first?["Icon"] == nil)
    }
}
