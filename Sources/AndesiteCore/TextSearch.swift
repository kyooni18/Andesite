import Foundation

/// A note containing the searched text, with the lines it appears on.
public struct TextSearchResult: Equatable, Sendable {
    public let entryID: Data
    public let path: String
    public let title: String
    /// Occurrences in the whole note (titles and paths are not searched).
    public let matchCount: Int
    /// The first matching lines, in order.
    public let lines: [TextSearchLine]
}

/// One matching line, trimmed around its first match when long.
public struct TextSearchLine: Equatable, Sendable {
    /// 1-based line number in the note.
    public let number: Int
    public let text: String
    /// Matches within `text`, as UTF-16 offsets.
    public let matches: [Range<Int>]
}

extension Vault {
    /// Finds `text` anywhere in note contents (substring, not word, matching).
    /// Scans the index a page at a time so other calls run in between, and
    /// stops early when the calling task is cancelled.
    public func searchText(_ text: String, caseSensitive: Bool = false, maximumResults: Int = 200,
                           linesPerResult: Int = 20) async throws -> [TextSearchResult] {
        guard !text.isEmpty, maximumResults > 0 else { return [] }
        var results: [TextSearchResult] = []
        var offset = 0
        while results.count < maximumResults {
            try Task.checkCancellation()
            let pageOffset = offset
            let found: (results: [TextSearchResult], next: Int?) = try await perform(.read) { runtime in
                let page = try runtime.documents(limit: 100, offset: pageOffset)
                var found: [TextSearchResult] = []
                for document in page.documents where document.kind == "markdown" {
                    guard let content = try? runtime.read(document.path).content,
                          let result = TextSearch.match(text, in: String(decoding: content, as: UTF8.self),
                                                        document: document, caseSensitive: caseSensitive,
                                                        linesPerResult: linesPerResult) else { continue }
                    found.append(result)
                }
                return (found, page.nextOffset)
            }
            results += found.results
            guard let next = found.next else { break }
            offset = next
        }
        return Array(results.prefix(maximumResults))
    }
}

enum TextSearch {
    /// Longest snippet shown for a line; longer lines are cut around the first match.
    static let snippetLength = 160

    static func match(_ needle: String, in content: String, document: IndexedDocument,
                      caseSensitive: Bool, linesPerResult: Int) -> TextSearchResult? {
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        guard content.range(of: needle, options: options) != nil else { return nil }
        var count = 0
        var lines: [TextSearchLine] = []
        var number = 0
        content.enumerateLines { line, _ in
            number += 1
            let ranges = occurrences(of: needle, in: line, options: options)
            guard !ranges.isEmpty else { return }
            count += ranges.count
            if lines.count < linesPerResult { lines.append(snippet(line, number: number, matches: ranges)) }
        }
        return TextSearchResult(entryID: document.id, path: document.path, title: document.title,
                                matchCount: count, lines: lines)
    }

    private static func occurrences(of needle: String, in line: String,
                                    options: String.CompareOptions) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = line.startIndex
        while start < line.endIndex, let found = line.range(of: needle, options: options, range: start..<line.endIndex) {
            ranges.append(found)
            start = found.upperBound
        }
        return ranges
    }

    /// The line (cut to `snippetLength` around its first match) with match offsets.
    private static func snippet(_ line: String, number: Int, matches: [Range<String.Index>]) -> TextSearchLine {
        let utf16 = line.utf16
        let offsets = matches.map { utf16.distance(from: utf16.startIndex, to: $0.lowerBound)
                                     ..< utf16.distance(from: utf16.startIndex, to: $0.upperBound) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard utf16.count > snippetLength else {
            let lead = utf16.distance(from: utf16.startIndex, to: line.range(of: trimmed)?.lowerBound ?? line.startIndex)
            return TextSearchLine(number: number, text: trimmed,
                                  matches: offsets.map { ($0.lowerBound - lead)..<($0.upperBound - lead) }
                                    .filter { $0.lowerBound >= 0 && $0.upperBound <= trimmed.utf16.count })
        }
        let first = offsets[0].lowerBound
        let start = max(0, min(first - snippetLength / 3, utf16.count - snippetLength))
        let end = min(utf16.count, start + snippetLength)
        let lower = String.Index(utf16Offset: start, in: line), upper = String.Index(utf16Offset: end, in: line)
        let prefix = start > 0 ? "…" : "", suffix = end < utf16.count ? "…" : ""
        let shift = prefix.utf16.count - start
        let text = prefix + String(line[lower..<upper]) + suffix
        return TextSearchLine(number: number, text: text,
                              matches: offsets.filter { $0.lowerBound >= start && $0.upperBound <= end }
                                .map { ($0.lowerBound + shift)..<($0.upperBound + shift) })
    }
}
