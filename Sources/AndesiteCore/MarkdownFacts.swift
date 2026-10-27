import Foundation
import Markdown

public enum MarkdownAnalysisError: Error, Equatable { case invalidUTF8 }

public struct MarkdownHeading: Equatable, Sendable {
    public let level: Int
    public let text: String
    public let startLine: Int?
    public let endLine: Int?
}

public struct MarkdownFacts: Equatable, Sendable {
    public let headings: [MarkdownHeading]
    public let linkDestinations: [String]
}

/// A deliberately limited CommonMark AST extraction primitive. It never
/// serializes Markdown or modifies the input. This is not the v1 indexer:
/// frontmatter, extension lexing, slugging, resolution and FTS are not here.
public enum MarkdownAnalyzer {
    public static func analyze(_ bytes: Data) throws -> MarkdownFacts {
        guard let source = String(data: bytes, encoding: .utf8) else { throw MarkdownAnalysisError.invalidUTF8 }
        let document = Document(parsing: source)
        var headings: [MarkdownHeading] = []
        var links: [String] = []
        func visit(_ node: any Markup) {
            if let heading = node as? Heading {
                headings.append(MarkdownHeading(level: heading.level, text: heading.plainText,
                    startLine: heading.range?.lowerBound.line, endLine: heading.range?.upperBound.line))
            }
            if let link = node as? Link, let destination = link.destination { links.append(destination) }
            for child in node.children { visit(child) }
        }
        visit(document)
        return MarkdownFacts(headings: headings, linkDestinations: links)
    }
}
