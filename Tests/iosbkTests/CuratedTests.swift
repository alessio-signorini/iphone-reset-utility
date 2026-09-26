import Foundation
import Testing
@testable import iosbk

@Suite("Curate profile.yml (generic multi-section)")
struct CuratedTests {
    @Test("multi-section profile.yml round-trips through encode/decode")
    func roundTrips() throws {
        let sections: [(key: String, items: [CuratedItem])] = [
            ("webclips", [CuratedItem(description: "Example -> https://example.com", keep: true)]),
            ("wifi", [
                CuratedItem(description: "HomeNet (WPA2)", keep: true),
                CuratedItem(description: "Cafe \"Guest\" (None, hidden)", keep: false),
            ]),
        ]
        let decoded = try CuratedProfile.decode(CuratedProfile.encode(sections: sections))
        #expect(decoded["webclips"] == sections[0].items)
        #expect(decoded["wifi"] == sections[1].items)
    }

    @Test("keptDescriptions returns only keep: true items, nil for an absent section")
    func keptDescriptionsFiltersAndDefaultsNil() throws {
        let sections = try CuratedProfile.decode(CuratedProfile.encode(sections: [
            ("wifi", [
                CuratedItem(description: "Keep1", keep: true),
                CuratedItem(description: "Drop", keep: false),
                CuratedItem(description: "Keep2", keep: true),
            ]),
        ]))
        #expect(CuratedProfile.keptDescriptions(for: "wifi", in: sections) == ["Keep1", "Keep2"])
        #expect(CuratedProfile.keptDescriptions(for: "accounts", in: sections) == nil)
    }

    @Test("deleted records and # comments are both honoured as de-selection")
    func commentsAndDeletionsPrune() throws {
        let yaml = """
        wifi:
          - description: "Keep"
            keep: true
        # the network below was pruned by deleting its record
        """
        let sections = try CuratedProfile.decode(Data(yaml.utf8))
        #expect(CuratedProfile.keptDescriptions(for: "wifi", in: sections) == ["Keep"])
    }

    @Test("a file with no root section is a clear error, not a crash")
    func malformedFileErrors() throws {
        #expect(throws: CurateYAML.YAMLError.self) {
            _ = try CuratedProfile.decode(Data("not yaml at all, just text\n".utf8))
        }
    }
}

