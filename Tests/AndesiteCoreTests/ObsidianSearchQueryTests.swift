import Foundation
import Testing
@testable import AndesiteCore

@Test func obsidianTagAndPropertySearchSubsetUsesTypedIndex() throws {
    let query = try ObsidianSearchQuery.parse(
        "rocket launch tag:#Project [priority:5]",
        explicitTag: nil, explicitProperty: nil, explicitValue: nil)
    #expect(query.phrase == "rocket launch")
    #expect(query.filter?.tag == "project")
    #expect(query.filter?.property == "priority")
    #expect(query.filter?.value == "5")

    let tagOnly = try ObsidianSearchQuery.parse(
        "tag:#inbox/active", explicitTag: nil,
        explicitProperty: nil, explicitValue: nil)
    #expect(tagOnly.phrase == nil)
    #expect(tagOnly.filter?.tag == "inbox/active")

    let propertyOnly = try ObsidianSearchQuery.parse(
        "[due date:2026-11-08]", explicitTag: nil,
        explicitProperty: nil, explicitValue: nil)
    #expect(propertyOnly.filter?.property == "due date")
    #expect(propertyOnly.filter?.value == "2026-11-08")

    #expect(throws: SearchIndexError.invalidQuery) {
        try ObsidianSearchQuery.parse("[rating:>5]", explicitTag: nil,
                                      explicitProperty: nil, explicitValue: nil)
    }
    #expect(throws: SearchIndexError.invalidQuery) {
        try ObsidianSearchQuery.parse("tag:#one tag:#two", explicitTag: nil,
                                      explicitProperty: nil, explicitValue: nil)
    }
    #expect(throws: SearchIndexError.invalidQuery) {
        try ObsidianSearchQuery.parse("tag:#one", explicitTag: "two",
                                      explicitProperty: nil, explicitValue: nil)
    }
}
