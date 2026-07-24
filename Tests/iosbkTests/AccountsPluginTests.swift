import Foundation
import Testing
@testable import iosbk

@Suite("AccountsPlugin")
struct AccountsPluginTests {
    @Test("classifies Mail and CalDAV accounts and skips unclassifiable ones from payloads")
    func classifiesKnownAccountTypes() throws {
        let backup = try Fixture.accountsBackup()
        let plugin = AccountsPlugin()
        let entries = try plugin.extract(backup, dryRun: false)
        #expect(entries.count == 3)

        let mail = try #require(entries.first { $0.kind == .mail })
        #expect(mail.description == "Work Mail")
        #expect(mail.username == "user@example.com")
        #expect(mail.hostName == "imap.example.com")

        let caldav = try #require(entries.first { $0.kind == .caldav })
        #expect(caldav.description == "Home Calendar")

        let other = try #require(entries.first { $0.kind == .other })
        #expect(other.description == "Mystery Account")

        // payloads() should only carry Mail/CalDAV/CardDAV/VPN, never "other".
        let payloads = plugin.payloads(entries)
        #expect(payloads.count == 2)
    }

    @Test("returns an empty list when Accounts3.sqlite is absent")
    func returnsEmptyWhenAccountsDatabaseMissing() throws {
        let backup = try Fixture.emptyBackup()
        let entries = try AccountsPlugin().extract(backup, dryRun: false)
        #expect(entries.isEmpty)
    }

    @Test("never emits a password field in generated payloads")
    func payloadsNeverIncludePassword() throws {
        let backup = try Fixture.accountsBackup()
        let plugin = AccountsPlugin()
        let entries = try plugin.extract(backup, dryRun: false)
        let payloads = plugin.payloads(entries)
        let data = try ProfileBuilder.build(payloads)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        let plistUnwrapped = try #require(plist)
        let content = try #require(plistUnwrapped["PayloadContent"] as? [[String: Any]])
        for entry in content {
            #expect(entry["Password"] == nil)
            #expect(entry["VPNPassword"] == nil)
        }
    }
}
