import Foundation
import Testing
@testable import iosbk

@Suite("CLI subcommands")
struct CLITests {
    @Test("--help renders for the root command and every subcommand")
    func helpRendersEverywhere() throws {
        for args in [["--help"], ["backups", "--help"], ["list", "--help"], ["extract", "--help"],
                     ["profile", "--help"], ["curate", "apps", "--help"],
                     ["install", "apps", "--help"], ["install", "profile", "--help"]] {
            let result = try CLI.run(args)
            #expect(result.status == 0, "iosbk \(args.joined(separator: " ")) exited \(result.status): \(result.stderr)")
            #expect(result.stdout.contains("USAGE") || result.stdout.contains("OVERVIEW"))
        }
    }

    @Test("list works against a fixture backup")
    func listWorksAgainstFixture() throws {
        let backup = try Fixture.webclipsBackup()
        let result = try CLI.run(["list", "--backup", backup.dir.path])
        #expect(result.status == 0)
        #expect(result.stdout.contains("webclips"))
        #expect(result.stdout.contains("2 item(s)")) // two web clips
        #expect(result.stdout.contains("apps"))
    }

    @Test("extract webclips works against a fixture and prints both clips")
    func extractWebclipsWorksAgainstFixture() throws {
        let backup = try Fixture.webclipsBackup()
        let result = try CLI.run(["extract", "webclips", "--backup", backup.dir.path])
        #expect(result.status == 0)
        #expect(result.stdout.contains("Example"))
        #expect(result.stdout.contains("noicon.org"))
    }

    @Test("extract --json prints valid JSON")
    func extractJSONIsValid() throws {
        let backup = try Fixture.webclipsBackup()
        let result = try CLI.run(["extract", "apps", "--backup", backup.dir.path, "--json"])
        #expect(result.status == 0)
        let data = try #require(result.stdout.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String].self, from: data)
        #expect(decoded == ["com.example.bar", "com.example.foo"])
    }

    @Test("profile webclips wifi accounts merges into a single valid profile with expected payload count")
    func profileMergesMultiplePlugins() throws {
        // Build one backup that satisfies all three plugins at once.
        let webclipFiles: [FixtureFile] = [
            FixtureFile(domain: "HomeDomain", rel: "Library/WebClips/example.com.webclip/Info.plist",
                        data: try Fixture.binaryPlist(["URL": "https://example.com", "Title": "Example", "FullScreen": true])),
            FixtureFile(domain: "HomeDomain", rel: "Library/WebClips/example.com.webclip/icon.png",
                        data: Fixture.onePixelPNG()),
        ]
        let wifiCandidate = WifiPlugin.candidatePaths[0]
        let wifiFiles: [FixtureFile] = [
            FixtureFile(domain: wifiCandidate.domain, rel: wifiCandidate.rel,
                        data: try Fixture.binaryPlist(["List": [["SSID_STR": "HomeNet", "EncryptionType": "WPA", "HIDDEN_NETWORK": false]]])),
        ]
        let backup = try Fixture.build(webclipFiles + wifiFiles)

        let outputPath = FileManager.default.temporaryDirectory.appending(path: "iosbk-out-\(UUID().uuidString).mobileconfig")
        defer { try? FileManager.default.removeItem(at: outputPath) }

        let result = try CLI.run(["profile", "webclips", "wifi", "--backup", backup.dir.path, "-o", outputPath.path])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: outputPath.path))

        let data = try Data(contentsOf: outputPath)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        let plistUnwrapped = try #require(plist)
        let content = try #require(plistUnwrapped["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 2) // 1 webclip + 1 wifi payload
        #expect(content.contains { ($0["Icon"] as? Data) != nil }) // icon preserved
    }

    @Test("encrypted backup surfaces a clear, non-crashing error")
    func encryptedBackupSurfacesCleanError() throws {
        let dir = try Fixture.encryptedBackup()
        let result = try CLI.run(["list", "--backup", dir.path])
        #expect(result.status != 0)
        #expect(result.stderr.lowercased().contains("encrypt"))
    }

    @Test("curate apps then install apps --strategy appstore-open prints the expected open command")
    func curateThenInstallAppsAppstoreOpen() throws {
        let appsYML = FileManager.default.temporaryDirectory.appending(path: "iosbk-apps-\(UUID().uuidString).yml")
        defer { try? FileManager.default.removeItem(at: appsYML) }
        let apps = [CuratedApp(bundleID: "com.example.foo", name: "Foo", storeID: 999, keep: true)]
        try AppsYAML.encode(apps).write(to: appsYML)

        let result = try CLI.run(["install", "apps", "--from", appsYML.path, "--strategy", "appstore-open"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("itms-apps://itunes.apple.com/app/id999"))
    }

    @Test("install profile prints (without --run) the cfgutil install-profile command")
    func installProfilePrintsCommand() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "iosbk-profile-\(UUID().uuidString).mobileconfig")
        try Data().write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let result = try CLI.run(["install", "profile", path.path])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("cfgutil install-profile"))
        #expect(result.stdout.contains(path.path))
    }
}
