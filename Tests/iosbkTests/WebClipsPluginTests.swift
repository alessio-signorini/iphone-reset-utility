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

    @Test("a Shortcuts web clip's unstable id is dropped, keeping only name")
    func stripsUnstableShortcutID() throws {
        let backup = try Fixture.build([
            FixtureFile(
                domain: "HomeDomain",
                rel: "Library/WebClips/shortcut.webclip/Info.plist",
                data: try Fixture.binaryPlist([
                    "URL": "shortcuts://x-callback-url/run-shortcut?name=Log%20Mood&id=D30C8F26-C30F-41B3-8F83-D1D1B2655433&source=homescreen",
                    "Title": "Log Mood",
                ])),
        ])
        let clips = try WebClipsPlugin().extract(backup, dryRun: false)
        #expect(clips.count == 1)
        let clip = try #require(clips.first)
        #expect(!clip.url.contains("id="))
        #expect(clip.url.contains("name=Log%20Mood") || clip.url.contains("name=Log+Mood"))
        #expect(clip.url.contains("source=homescreen"))

        #expect(WebClipsPlugin().describe(clip).contains("runs Shortcut \"Log Mood\" by name"))
    }

    @Test("flags whether the target Shortcut was also recovered from the backup")
    func flagsShortcutAvailability() throws {
        let shortcutClipInfo: (String) -> Data = { name in
            try! Fixture.binaryPlist([
                "URL": "shortcuts://x-callback-url/run-shortcut?name=\(name.replacingOccurrences(of: " ", with: "%20"))",
                "Title": name,
            ])
        }
        let backup = try Fixture.build([
            FixtureFile(
                domain: "HomeDomain", rel: "Library/WebClips/found.webclip/Info.plist",
                data: shortcutClipInfo("Log Mood")),
            FixtureFile(
                domain: "HomeDomain", rel: "Library/WebClips/missing.webclip/Info.plist",
                data: shortcutClipInfo("Deleted Shortcut")),
            FixtureFile(
                domain: ShortcutsExport.domain, rel: "Documents/Log Mood.shortcut",
                data: Data("SHORTCUT".utf8)),
        ])
        let clips = try WebClipsPlugin().extract(backup, dryRun: false)

        let found = try #require(clips.first { $0.title == "Log Mood" })
        #expect(found.shortcutFound == true)
        #expect(WebClipsPlugin().describe(found).contains("found in this backup"))

        let missing = try #require(clips.first { $0.title == "Deleted Shortcut" })
        #expect(missing.shortcutFound == false)
        #expect(WebClipsPlugin().describe(missing).contains("not found in this backup"))
    }
}
