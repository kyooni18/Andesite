import Foundation

/// One link as written in a note. `targetRange` is the byte range of the
/// target text in the file, so a rename can replace exactly that text.
public struct ObsidianLink: Equatable, Sendable {
    /// "wikilink" (`[[target#fragment|display]]`) or "markdown" (`[display](target#fragment)`).
    public let syntax: String
    /// As written (Markdown targets are still percent-encoded).
    public let target: String
    public let fragment: String?
    public let display: String?
    public let embed: Bool
    public let targetRange: Range<Int>
}

/// Lexes Obsidian wikilinks and inline Markdown links with their positions.
/// Code fences, indented code, inline code and escaped brackets are skipped.
/// In YAML frontmatter only wikilinks count, as in Obsidian properties.
public enum ObsidianLinks {
    public static func extract(_ text: String) -> [ObsidianLink] { extract(Data(text.utf8)) }

    public static func extract(_ data: Data) -> [ObsidianLink] {
        let bytes = [UInt8](data)
        var links: [ObsidianLink] = []
        var fence: (symbol: UInt8, count: Int)?
        var frontmatter = bytes.starts(with: Array("---\n".utf8)) || bytes.starts(with: Array("---\r\n".utf8))
        var lineStart = 0, first = true
        while lineStart < bytes.count || first {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            defer { lineStart = lineEnd + 1; first = false }
            let line = lineStart..<lineEnd
            let trimmed = String(decoding: bytes[line], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if frontmatter {
                if !first, trimmed == "---" || trimmed == "..." { frontmatter = false; continue }
                lexLine(bytes, line, markdownLinks: false, into: &links)
                continue
            }
            let indent = bytes[line].prefix { $0 == 0x20 }.count
            let body = bytes[(lineStart + min(indent, 3))..<lineEnd]
            if let active = fence {
                let run = body.prefix { $0 == active.symbol }.count
                if run >= active.count, body.dropFirst(run).allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { fence = nil }
                continue
            }
            if indent <= 3, let symbol = body.first, symbol == 0x60 || symbol == 0x7E {
                let run = body.prefix { $0 == symbol }.count
                if run >= 3 { fence = (symbol, run); continue }
            }
            if indent >= 4 { continue }
            lexLine(bytes, line, markdownLinks: true, into: &links)
        }
        return links
    }

    private static func lexLine(_ b: [UInt8], _ line: Range<Int>, markdownLinks: Bool, into links: inout [ObsidianLink]) {
        var i = line.lowerBound
        var code: Int? // length of the open inline-code backtick run
        while i < line.upperBound {
            let c = b[i]
            if c == 0x5C { i += 2; continue } // backslash escape
            if c == 0x60 {
                var end = i
                while end < line.upperBound, b[end] == 0x60 { end += 1 }
                if code == nil { code = end - i } else if code == end - i { code = nil }
                i = end
                continue
            }
            if code != nil { i += 1; continue }
            let embed = c == 0x21 && i + 1 < line.upperBound && b[i + 1] == 0x5B
            let open = embed ? i + 1 : i
            guard open < line.upperBound, b[open] == 0x5B else { i += 1; continue }
            if open + 1 < line.upperBound, b[open + 1] == 0x5B {
                if let (link, end) = wikilink(b, open, line.upperBound, embed: embed) { links.append(link); i = end; continue }
            } else if markdownLinks, let (link, end) = markdownLink(b, open, line.upperBound, embed: embed) {
                links.append(link); i = end; continue
            }
            i = open + 1
        }
    }

    /// `[[target#fragment|display]]` starting at `open` (the first "[").
    private static func wikilink(_ b: [UInt8], _ open: Int, _ limit: Int, embed: Bool) -> (ObsidianLink, Int)? {
        var close = open + 2
        while close + 1 < limit, !(b[close] == 0x5D && b[close + 1] == 0x5D) {
            if b[close] == 0x5B || b[close] == 0x5D { return nil }
            close += 1
        }
        guard close + 1 < limit, close - open <= 1024 else { return nil }
        let inner = (open + 2)..<close
        let pipe = b[inner].firstIndex(of: 0x7C) ?? close
        let hash = b[(open + 2)..<pipe].firstIndex(of: 0x23) ?? pipe
        var start = open + 2, end = hash
        while start < end, b[start] == 0x20 { start += 1 }
        while end > start, b[end - 1] == 0x20 { end -= 1 }
        let fragment = hash < pipe ? text(b, (hash + 1)..<pipe) : nil
        guard start < end || fragment.map({ !$0.isEmpty }) == true else { return nil }
        let link = ObsidianLink(syntax: "wikilink", target: text(b, start..<end), fragment: fragment,
                                display: pipe < close ? text(b, (pipe + 1)..<close) : nil, embed: embed,
                                targetRange: start..<end)
        return (link, close + 2)
    }

    /// `[display](target#fragment "title")` starting at `open` (the "[").
    private static func markdownLink(_ b: [UInt8], _ open: Int, _ limit: Int, embed: Bool) -> (ObsidianLink, Int)? {
        var depth = 0, close = open
        while close < limit {
            if b[close] == 0x5C { close += 2; continue }
            if b[close] == 0x5B { depth += 1 }
            if b[close] == 0x5D { depth -= 1; if depth == 0 { break } }
            close += 1
        }
        guard close + 1 < limit, b[close] == 0x5D, b[close + 1] == 0x28 else { return nil }
        var start = close + 2
        while start < limit, b[start] == 0x20 { start += 1 }
        var end = start, finish: Int
        if start < limit, b[start] == 0x3C { // <destination with spaces>
            start += 1; end = start
            while end < limit, b[end] != 0x3E { end += 1 }
            guard end < limit else { return nil }
            finish = end + 1
        } else {
            var parens = 0
            while end < limit, b[end] != 0x20 {
                if b[end] == 0x28 { parens += 1 }
                if b[end] == 0x29 { if parens == 0 { break }; parens -= 1 }
                end += 1
            }
            finish = end
        }
        while finish < limit, b[finish] != 0x29 { finish += 1 } // optional title
        guard finish < limit, start < end else { return nil }
        let hash = b[start..<end].firstIndex(of: 0x23) ?? end
        let link = ObsidianLink(syntax: "markdown", target: text(b, start..<hash),
                                fragment: hash < end ? text(b, (hash + 1)..<end) : nil,
                                display: text(b, (open + 1)..<close), embed: embed, targetRange: start..<hash)
        return (link, finish + 1)
    }

    private static func text(_ b: [UInt8], _ range: Range<Int>) -> String { String(decoding: b[range], as: UTF8.self) }
}
