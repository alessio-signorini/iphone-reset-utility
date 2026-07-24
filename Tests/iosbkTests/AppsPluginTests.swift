import Foundation
import Testing
@testable import iosbk

@Suite("AppsPlugin")
struct AppsPluginTests {
    @Test("extracts distinct, sorted bundle IDs from AppDomain-* entries")
    func extractsSortedBundleIDs() throws {
        let backup = try Fixture.webclipsBackup() // includes two AppDomain-* rows
        let bundleIDs = try AppsPlugin().extract(backup, dryRun: false)
        #expect(bundleIDs == ["com.example.bar", "com.example.foo"])
    }

    @Test("curate(bundleIDs:client:nil) emits unenriched entries with keep=true")
    func curateWithoutEnrichment() async throws {
        let apps = await AppsPlugin.curate(bundleIDs: ["com.b", "com.a"], client: nil)
        #expect(apps.map(\.bundleID) == ["com.a", "com.b"])
        #expect(apps.allSatisfy { $0.name == nil && $0.storeID == nil && $0.keep })
    }

    @Test("curate(bundleIDs:client:) enriches via the injected lookup client, no live network")
    func curateWithMockEnrichment() async throws {
        struct MockClient: ITunesLookupClient {
            func lookup(bundleID: String) async throws -> ITunesLookupResult? {
                guard bundleID == "com.example.foo" else { return nil }
                return ITunesLookupResult(name: "Foo App", storeID: 123456)
            }
        }
        let apps = await AppsPlugin.curate(bundleIDs: ["com.example.foo", "com.example.unknown"], client: MockClient())
        let foo = try #require(apps.first { $0.bundleID == "com.example.foo" })
        #expect(foo.name == "Foo App")
        #expect(foo.storeID == 123456)

        let unknown = try #require(apps.first { $0.bundleID == "com.example.unknown" })
        #expect(unknown.name == nil)
        #expect(unknown.storeID == nil)
    }

    @Test("apps.yml round-trips through AppsYAML.encode/decode")
    func yamlRoundTrips() throws {
        let apps = [
            CuratedApp(bundleID: "com.example.foo", name: "Foo App", storeID: 123456, keep: true),
            CuratedApp(bundleID: "com.example.bar", name: nil, storeID: nil, keep: false),
        ]
        let data = AppsYAML.encode(apps)
        let decoded = try AppsYAML.decode(data)
        #expect(decoded == apps)
    }

    @Test("restoreCommands(strategy: .cfgutil) emits install-app for apps with a matching .ipa, warns otherwise")
    func cfgutilStrategyRestoreCommands() throws {
        let ipaDir = FileManager.default.temporaryDirectory.appending(path: "iosbk-ipas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ipaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ipaDir) }
        try Data().write(to: ipaDir.appending(path: "com.example.foo.ipa"))

        let apps = [
            CuratedApp(bundleID: "com.example.foo", name: "Foo", storeID: nil, keep: true),
            CuratedApp(bundleID: "com.example.bar", name: "Bar", storeID: nil, keep: true),
            CuratedApp(bundleID: "com.example.skip", name: "Skip", storeID: nil, keep: false),
        ]
        let (commands, warnings) = AppsPlugin.restoreCommands(apps: apps, strategy: .cfgutil, ipaDir: ipaDir)
        #expect(commands.count == 1)
        #expect(commands.first?.contains("com.example.foo.ipa") == true)
        #expect(warnings.contains { $0.contains("com.example.bar") })
        #expect(!warnings.contains { $0.contains("com.example.skip") }) // keep=false: silently excluded
    }

    @Test("restoreCommands(strategy: .appstoreOpen) emits an itms-apps open URL only for enriched apps")
    func appstoreOpenStrategyRestoreCommands() throws {
        let apps = [
            CuratedApp(bundleID: "com.example.foo", name: "Foo", storeID: 123456, keep: true),
            CuratedApp(bundleID: "com.example.bar", name: "Bar", storeID: nil, keep: true),
        ]
        let (commands, warnings) = AppsPlugin.restoreCommands(apps: apps, strategy: .appstoreOpen, ipaDir: nil)
        #expect(commands == ["open \"itms-apps://itunes.apple.com/app/id123456\""])
        #expect(warnings.contains { $0.contains("com.example.bar") })
    }
}
