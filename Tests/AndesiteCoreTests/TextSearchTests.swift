import Foundation
import Testing
@testable import AndesiteCore

@Test func textSearchFindsSubstringsWithLinesAndHighlights() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("Numbers.md", "# Numbers\n20950912, 7140 3432\nnothing here\n23세기\n")
    try f.write("Other.md", "# Other\nno digits\n")
    try f.write("Long.md", String(repeating: "word ", count: 60) + "needle3 " + String(repeating: "tail ", count: 60))
    let session = try Vault(at: f.vault.path, options: .init(stateDirectory: f.state.path, watch: false))
    defer { try? session.close() }
    try session.reconcile()

    let results = try await session.searchText("3")
    #expect(Set(results.map(\.path)) == ["Numbers.md", "Long.md"])
    let numbers = try #require(results.first { $0.path == "Numbers.md" })
    #expect(numbers.matchCount == 3)  // two in "3432", one in "23세기"
    #expect(numbers.lines.map(\.number) == [2, 4])
    let line = numbers.lines[0]
    let highlighted = line.matches.map { range in
        String(line.text.utf16.dropFirst(range.lowerBound).prefix(range.count))!
    }
    #expect(highlighted == ["3", "3"])

    // Long lines are cut around the match, keeping the highlight on it.
    let long = try #require(results.first { $0.path == "Long.md" }?.lines.first)
    #expect(long.text.hasPrefix("…") && long.text.hasSuffix("…"))
    #expect(long.text.utf16.count <= TextSearch.snippetLength + 2)
    let hit = long.matches[0]
    #expect(String(long.text.utf16.dropFirst(hit.lowerBound).prefix(hit.count)) == "3")

    #expect(try await session.searchText("NUMBERS", caseSensitive: true).isEmpty)
    #expect(try await session.searchText("NUMBERS").map(\.path) == ["Numbers.md"])
}
