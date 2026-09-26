import Foundation
import Testing
@testable import iosbk

@Suite("CLI subcommands")
struct CLITests {
    @Test("--help renders for the root command and every subcommand")
    func helpRendersEverywhere() throws {
        for args in [["-​-help"], ["backups", "--help"], ["list", "--help"],
                     ["profile", "--help"], ["profile", "curate", "--help"], ["profile", "install", "--help"],
                     ["apps", "--help"], ["apps", "curate", "--help"],
                     ["apps", "download", "--help"], ["apps", "install", "--help"],
                     ["wallet", "--help"], ["wallet", "export", "--help"],
                     ["photos", "--help"], ["photos", "export", "--help"],
                     ["messages", "dump", "--help"], ["notes", "dump", "--help"],
                     ["health", "dump", "--help"], ["calls", "dump", "--help"],
                     ["voicemail", "dump", "--help"], ["bluetooth", "dump", "--help"],
                     ["reminders", "dump", "--help"], ["bookmarks", "dump", "--help"]] {
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
        #expect(result.stdout.contains("    2")) // two web clips, right-aligned count
        #expect(result.stdout.contains("apps"))
    }

    @Test("profile curate then install merges plugins into a single valid profile")
    func profileCurateThenInstallMergesPlugins() throws {
        // Build one backup that satisfies both plugins at once.
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

        let curatedPath = FileManager.default.temporaryDirectory.appending(path: "iosbk-profile-\(UUID().uuidString).yml")
        let outputPath = FileManager.default.temporaryDirectory.appending(path: "iosbk-out-\(UUID().uuidString).mobileconfig")
        defer {
            try? FileManager.default.removeItem(at: curatedPath)
            try? FileManager.default.removeItem(at: outputPath)
        }

        let curate = try CLI.run(["profile", "curate", "--keys", "webclips,wifi", "--backup", backup.dir.path, "-o", curatedPath.path])
        #expect(curate.status == 0, "\(curate.stderr)")
        let curatedText = try String(contentsOf: curatedPath, encoding: .utf8)
        #expect(curatedText.contains("webclips:"))
        #expect(curatedText.contains("wifi:"))

        let install = try CLI.run(["profile", "install", curatedPath.path, "--backup", backup.dir.path, "-o", outputPath.path])
        #expect(install.status == 0, "\(install.stderr)")
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

    @Test("apps curate then apps install --strategy appstore-open --print-only prints the expected open command")
    func curateThenInstallAppsAppstoreOpen() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appending(path: "iosbk-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let apps = [CuratedApp(bundleID: "com.example.foo", name: "Foo", storeID: 999, keep: true)]
        try AppsYAML.encode(apps).write(to: tmpDir.appending(path: "list.yml"))

        let result = try CLI.run(["apps", "install", "--dir", tmpDir.path,
                                  "--strategy", "appstore-open", "--print-only"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("itms-apps://itunes.apple.com/app/id999"))
    }

    @Test("editing a curated profile.yml's keep flag drops that item from install")
    func editingCuratedFileDropsItem() throws {
        let wifiCandidate = WifiPlugin.candidatePaths[0]
        let wifiFiles: [FixtureFile] = [
            FixtureFile(domain: wifiCandidate.domain, rel: wifiCandidate.rel,
                        data: try Fixture.binaryPlist(["List": [
                            ["SSID_STR": "HomeNet", "EncryptionType": "WPA2", "HIDDEN_NETWORK": false],
                            ["SSID_STR": "AirportFree", "EncryptionType": "None", "HIDDEN_NETWORK": false],
                        ]])),
        ]
        let backup = try Fixture.build(wifiFiles)

        let curatedPath = FileManager.default.temporaryDirectory.appending(path: "iosbk-profile-\(UUID().uuidString).yml")
        let outputPath = FileManager.default.temporaryDirectory.appending(path: "iosbk-out-\(UUID().uuidString).mobileconfig")
        defer {
            try? FileManager.default.removeItem(at: curatedPath)
            try? FileManager.default.removeItem(at: outputPath)
        }

        let curate = try CLI.run(["profile", "curate", "--keys", "wifi", "--backup", backup.dir.path, "-o", curatedPath.path])
        #expect(curate.status == 0, "\(curate.stderr)")

        // Hand-edit: drop AirportFree by flipping its keep flag (as a user
        // would in a text editor).
        var text = try String(contentsOf: curatedPath, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "description: \"AirportFree (None)\"\n    keep: true",
            with: "description: \"AirportFree (None)\"\n    keep: false")
        try text.write(to: curatedPath, atomically: true, encoding: .utf8)

        let install = try CLI.run(["profile", "install", curatedPath.path, "--backup", backup.dir.path, "-o", outputPath.path])
        #expect(install.status == 0, "\(install.stderr)")

        let data = try Data(contentsOf: outputPath)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        let plistUnwrapped = try #require(plist)
        let content = try #require(plistUnwrapped["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content.first?["SSID_STR"] as? String == "HomeNet")
    }

    @Test("profile install without --run only prints the cfgutil command")
    func installWithoutRunOnlyPrints() throws {
        let webclipFiles: [FixtureFile] = [
            FixtureFile(domain: "HomeDomain", rel: "Library/WebClips/example.com.webclip/Info.plist",
                        data: try Fixture.binaryPlist(["URL": "https://example.com", "Title": "Example", "FullScreen": true])),
        ]
        let backup = try Fixture.build(webclipFiles)

        let curatedPath = FileManager.default.temporaryDirectory.appending(path: "iosbk-profile-\(UUID().uuidString).yml")
        let outputPath = FileManager.default.temporaryDirectory.appending(path: "iosbk-out-\(UUID().uuidString).mobileconfig")
        defer {
            try? FileManager.default.removeItem(at: curatedPath)
            try? FileManager.default.removeItem(at: outputPath)
        }

        let curate = try CLI.run(["profile", "curate", "--keys", "webclips", "--backup", backup.dir.path, "-o", curatedPath.path])
        #expect(curate.status == 0, "\(curate.stderr)")

        let install = try CLI.run(["profile", "install", curatedPath.path, "--backup", backup.dir.path, "-o", outputPath.path])
        #expect(install.status == 0, "\(install.stderr)")
        #expect(install.stdout.contains("cfgutil install-profile"))
        #expect(install.stdout.contains(outputPath.path))
        #expect(FileManager.default.fileExists(atPath: outputPath.path))
    }
}
