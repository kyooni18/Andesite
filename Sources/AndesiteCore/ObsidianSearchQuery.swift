import Foundation

/// Supported safe subset of Obsidian's search language:
///   tag:#parent, [property], [property:value], and an optional literal
///   free-text phrase. Nested boolean expressions, regexes, inequalities,
///   quoted operator values, and arbitrary query DSLs are not interpreted.
public struct ObsidianSearchQuery {
    public let phrase: String?
    public let filter: ObsidianFilter?

    public static func parse(_ raw: String, explicitTag: String?,
                             explicitProperty: String?,
                             explicitValue: String?) throws -> ObsidianSearchQuery {
        guard raw.utf8.count <= 1024 else { throw SearchIndexError.invalidQuery }
        let pattern = #"(?:^|[ \t])(tag:[^ \t]+|\[[^\]\r\n]{1,512}\])(?=[ \t]|$)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, range: range)
        var extractedTag: String?
        var extractedName: String?
        var extractedValue: String?
        var phrase = raw
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: raw),
                  let operatorRange = Range(match.range(at: 1), in: raw) else {
                throw SearchIndexError.invalidQuery
            }
            let token = String(raw[operatorRange])
            if token.hasPrefix("tag:") {
                guard extractedTag == nil else { throw SearchIndexError.invalidQuery }
                extractedTag = String(token.dropFirst(4))
            } else if token.hasPrefix("[") && token.hasSuffix("]") {
                guard extractedName == nil else { throw SearchIndexError.invalidQuery }
                let contents = token.dropFirst().dropLast()
                let parts = contents.split(separator: ":", maxSplits: 1,
                                           omittingEmptySubsequences: false)
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { throw SearchIndexError.invalidQuery }
                extractedName = key
                if parts.count == 2 {
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    // Do not accidentally convert an unsupported Obsidian
                    // comparison operator into a misleading equality query.
                    guard !value.isEmpty, !value.hasPrefix("<"),
                          !value.hasPrefix(">"), !value.contains(" OR "),
                          !value.hasPrefix("/") else { throw SearchIndexError.invalidQuery }
                    extractedValue = value
                }
            }
            phrase.removeSubrange(matchRange)
        }
        let tag = try merge(explicitTag, extractedTag)
        let name = try merge(explicitProperty, extractedName)
        let value = try merge(explicitValue, extractedValue)
        let selectedFilter: ObsidianFilter?
        if tag != nil || name != nil || value != nil {
            selectedFilter = try ObsidianFilter(tag: tag, property: name, value: value)
        } else {
            selectedFilter = nil
        }
        let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || selectedFilter != nil else {
            throw SearchIndexError.invalidQuery
        }
        return ObsidianSearchQuery(
            phrase: normalized.isEmpty ? nil : normalized, filter: selectedFilter)
    }

    private static func merge(_ explicit: String?, _ implicit: String?) throws -> String? {
        if let explicit, let implicit,
           ObsidianMetadataParser.canonicalProperty(explicit) !=
           ObsidianMetadataParser.canonicalProperty(implicit) {
            throw SearchIndexError.invalidQuery
        }
        return explicit ?? implicit
    }
}
