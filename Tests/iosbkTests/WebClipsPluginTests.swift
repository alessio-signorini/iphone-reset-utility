import Foundation
import Testing
@testable import iosbk

@Suite("WebClipsPlugin")
struct WebClipsPluginTests {
    @Test("extracts both webclips, skipping the directory row, noise, and the URL-less clip")
    func extractsExpectedClips() throws {
        let backup = try Fixture.webclipsBackup()
        let plugin = WebClipsPlugin()
        let clips = try plugin.extract(backup, dryRun: false)

        #expect(clips.count == 2)
        let example = try #require(clips.first { $0.bundle == "example.com.webclip" })
        #expect(example.title == "Example")
        #expect(example.url == "https://example.com")
        #expect(example.fullScreen == true)
        #expect(example.icon == Fixture.onePixelPNG(tag: "example"))

        let noIcon = try #require(clips.first { $0.bundle == "noicon.org.webclip" })
        #expect(noIcon.title == "No Icon")
        #expect(noIcon.icon == nil)
    }

    @Test("falls back to the bundle name (minus .webclip) when Title is missing")
    func fallsBackToBundleNameForTitle() throws {
        let backup = try Fixture.build([
            FixtureFile(
                domain: "HomeDomain",
                rel: "Library/WebClips/notitle.example.webclip/Info.plist",
                data: try Fixture.binaryPlist(["URL": "https://notitle.example"])),
        ])
        let clips = try WebClipsPlugin().extract(backup, dryRun: false)
        #expect(clips.count == 1)
        #expect(clips.first?.title == "notitle.example")
    }

    @Test("payloads() produces one WebClipPayload per clip with icon data preserved")
    func payloadsRoundTripIcon() throws {
        let backup = try Fixture.webclipsBackup()
        let plugin = WebClipsPlugin()
        let clips = try plugin.extract(backup, dryRun: false)
        let payloads = plugin.payloads(clips)
        #expect(payloads.count == 2)

        let data = try ProfileBuilder.build(payloads)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        let plistUnwrapped = try #require(plist)
        let content = try #require(plistUnwrapped["PayloadContent"] as? [[String: Any]])
        let withIcon = try #require(content.first { ($0["Icon"] as? Data) != nil })
        #expect(withIcon["Icon"] as? Data == Fixture.onePixelPNG(tag: "example"))
    }
}
