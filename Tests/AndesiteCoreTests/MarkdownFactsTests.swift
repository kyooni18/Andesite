import Foundation
import Testing
@testable import AndesiteCore

@Test func markdownASTExtractionPreservesInput() throws {
    let input = Data("# Hello *world*\r\n\r\n[link](other.md) and `not [a link](x)`\r\n\r\n## Second\r\n".utf8)
    let original = input
    let facts = try MarkdownAnalyzer.analyze(input)
    #expect(facts.headings.map(\.level) == [1, 2])
    #expect(facts.headings.map(\.text) == ["Hello world", "Second"])
    #expect(facts.linkDestinations == ["other.md"])
    #expect(input == original)
    #expect(throws: MarkdownAnalysisError.invalidUTF8) { try MarkdownAnalyzer.analyze(Data([0xff])) }
}
