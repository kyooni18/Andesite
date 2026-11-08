import Foundation

public struct ObsidianWikiLink: Equatable, Sendable {
    public let target: String
    public let fragment: String?
    public let alias: String?
    public let embed: Bool
}

/// Conservative syntax extraction, NOT Obsidian's complete target resolver.
/// It recognizes wiki embeds, aliases and anchors but does not disambiguate
/// filenames, aliases, block targets or missing links against a Vault index.
/// Fenced/inline code and escaped brackets are excluded.
public enum ObsidianLinks {
    public static func extract(_ markdown: String) -> [ObsidianWikiLink] {
        var output: [ObsidianWikiLink] = []
        var fence: (symbol: Character, count: Int)?
        for line in markdown.components(separatedBy: .newlines) {
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let body = leadingSpaces <= 3 ? String(line.dropFirst(leadingSpaces)) : line
            let marker = body.prefix(while: { $0 == "`" || $0 == "~" })
            if let active = fence {
                if body.first == active.symbol {
                    let count = body.prefix(while: { $0 == active.symbol }).count
                    if count >= active.count &&
                       body.dropFirst(count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                        fence = nil
                    }
                }
                continue
            }
            if leadingSpaces <= 3, marker.count >= 3,
               let first = marker.first,
               marker.allSatisfy({ $0 == first }) {
                fence = (first, marker.count)
                continue
            }
            if leadingSpaces >= 4 { continue }

            let chars = Array(line)
            var offset = 0
            var inlineDelimiter: Int?
            while offset < chars.count {
                if chars[offset] == "\\" {
                    offset = min(offset + 2, chars.count)
                    continue
                }
                if chars[offset] == "`" {
                    var end = offset + 1
                    while end < chars.count && chars[end] == "`" { end += 1 }
                    let run = end - offset
                    if inlineDelimiter == nil { inlineDelimiter = run }
                    else if inlineDelimiter == run { inlineDelimiter = nil }
                    offset = end
                    continue
                }
                if inlineDelimiter != nil {
                    offset += 1
                    continue
                }
                let embed = chars[offset] == "!" &&
                    offset + 2 < chars.count &&
                    chars[offset + 1] == "[" && chars[offset + 2] == "["
                let start = embed ? offset + 1 : offset
                if start + 1 < chars.count && chars[start] == "[" && chars[start + 1] == "[" {
                    var end = start + 2
                    while end + 1 < chars.count {
                        if chars[end] == "]" && chars[end + 1] == "]" { break }
                        if chars[end] == "[" || chars[end] == "]" { break }
                        end += 1
                    }
                    if end + 1 < chars.count && chars[end] == "]" && chars[end + 1] == "]" &&
                       end - start <= 257 {
                        let inner = String(chars[(start + 2)..<end])
                        let display = inner.split(separator: "|", maxSplits: 1,
                                                  omittingEmptySubsequences: false)
                        let ref = String(display[0]).trimmingCharacters(in: .whitespaces)
                        let anchor = ref.split(separator: "#", maxSplits: 1,
                                               omittingEmptySubsequences: false)
                        let target = String(anchor[0]).trimmingCharacters(in: .whitespaces)
                        let fragment = anchor.count == 2 ? String(anchor[1]) : nil
                        let alias = display.count == 2 ? String(display[1]) : nil
                        if !target.isEmpty || (fragment != nil && fragment != "") {
                            output.append(ObsidianWikiLink(target: target,
                                                           fragment: fragment,
                                                           alias: alias, embed: embed))
                        }
                        offset = end + 2
                        continue
                    }
                }
                offset += 1
            }
        }
        return output
    }
}
