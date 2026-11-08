import Foundation
import Yams

public enum ObsidianMetadataError: Error, Equatable {
    case malformed(String)
    case resourceLimit
}

public struct ObsidianTag: Equatable, Sendable {
    public let name: String
    public let canonical: String
    public let origin: String
}

public struct ObsidianScalarIndex: Equatable, Sendable {
    public let property: String
    public let ordinal: Int
    public let type: String
    public let text: String
}

/// A derived projection, never a serialization of a user's YAML source.
/// Parsing errors are recorded per note; they never rewrite its bytes.
public struct ObsidianMetadata {
    public let properties: [[String: Any]]
    public let tags: [ObsidianTag]
    public let scalars: [ObsidianScalarIndex]
    public let state: String
    public let diagnostic: String?
    public let body: String
    /// Number of lines before the Markdown body, used to preserve source
    /// locations in outline APIs without interpreting YAML as Markdown.
    public let bodyLineOffset: Int

    public var propertiesJSON: String {
        guard let bytes = try? JSONSerialization.data(withJSONObject: properties,
                                                       options: [.sortedKeys, .fragmentsAllowed]),
              let string = String(data: bytes, encoding: .utf8) else { return "[]" }
        return string
    }
}

public enum ObsidianMetadataParser {
    public static let maximumFrontmatterBytes = 64 * 1024
    private static let maximumProperties = 128
    private static let maximumCollection = 256
    private static let maximumDepth = 10

    public static func canonicalTag(_ raw: String) -> String? {
        let name = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard !name.isEmpty, name.utf8.count <= 256,
              !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.contains("//") else { return nil }
        var hasNonDigit = false
        for c in name.unicodeScalars {
            if c == "<" || c == ">" || c == "+" || c == "=" { return nil }
            switch c.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter, .nonspacingMark,
                 .spacingMark, .enclosingMark, .decimalNumber,
                 .letterNumber, .otherNumber, .otherSymbol, .modifierSymbol,
                 .mathSymbol, .currencySymbol:
                if c.properties.generalCategory != .decimalNumber &&
                   c.properties.generalCategory != .letterNumber &&
                   c.properties.generalCategory != .otherNumber {
                    hasNonDigit = true
                }
            default:
                if c == "_" || c == "-" { hasNonDigit = true }
                else if c != "/" && c != "\u{200D}" { return nil }
            }
        }
        guard hasNonDigit else { return nil }
        return name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    public static func canonicalProperty(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    public static func parse(_ bytes: Data) throws -> ObsidianMetadata {
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw MarkdownAnalysisError.invalidUTF8
        }
        let normalized = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var yaml: String?
        var body = normalized
        var bodyLineOffset = 0
        var invalidHeader: String?
        if normalized.hasPrefix("---\n") || normalized.hasPrefix("---\r\n") ||
           normalized == "---" {
            let lines = normalized.components(separatedBy: "\n")
            var end: Int?
            var headerBytes = 0
            for index in 1..<min(lines.count, 8192) {
                let line = lines[index]
                let part = line.hasSuffix("\r") ? String(line.dropLast()) : line
                if part == "---" || part == "..." { end = index; break }
                headerBytes += line.utf8.count + 1
                if headerBytes > maximumFrontmatterBytes {
                    invalidHeader = "frontmatter_exceeds_64kib"
                    break
                }
            }
            if let end {
                yaml = lines[1..<end].joined(separator: "\n")
                body = lines.dropFirst(end + 1).joined(separator: "\n")
                bodyLineOffset = end + 1
            } else {
                invalidHeader = invalidHeader ?? "unterminated_frontmatter"
                // Unclosed YAML is not body prose; avoid inventing tags from
                // what may be a property value.
                body = ""
            }
        }

        var properties: [[String: Any]] = []
        var scalars: [ObsidianScalarIndex] = []
        var rawTags: [ObsidianTag] = []
        var state = "absent"
        var diagnostic = invalidHeader

        if let yaml, invalidHeader == nil {
            do {
                guard yaml.utf8.count <= maximumFrontmatterBytes else {
                    throw ObsidianMetadataError.resourceLimit
                }
                let parsed = try compose(yaml: yaml)
                if let parsed {
                    guard case .mapping(let mapping) = parsed else {
                        throw ObsidianMetadataError.malformed("root_must_be_mapping")
                    }
                    guard mapping.count <= maximumProperties else {
                        throw ObsidianMetadataError.resourceLimit
                    }
                    var seen: Set<String> = []
                    for (keyNode, valueNode) in mapping {
                        guard case .scalar(let keyScalar) = keyNode else {
                            throw ObsidianMetadataError.malformed("non_text_property_name")
                        }
                        let name = keyScalar.string
                        guard !name.isEmpty, name.utf8.count <= 256 else {
                            throw ObsidianMetadataError.malformed("invalid_property_name")
                        }
                        let key = canonicalProperty(name)
                        guard seen.insert(key).inserted else {
                            throw ObsidianMetadataError.malformed("duplicate_property_name")
                        }
                        let property = try convert(valueNode, depth: 0)
                        let kind = key == "tags" ? "tags" : property.kind
                        properties.append([
                            "name": name, "type": kind,
                            "value": property.json
                        ])
                        if let items = property.items {
                            for (index, value) in items.enumerated() {
                                scalars.append(ObsidianScalarIndex(
                                    property: key, ordinal: index,
                                    type: value.kind, text: value.text))
                            }
                        }
                        if key == "tags" {
                            // Obsidian's tags property uses a YAML sequence.
                            // Empty tag fields are legitimate placeholders
                            // when created through Obsidian's Properties UI.
                            if case .scalar = valueNode, property.kind == "null" {
                                continue
                            }
                            guard case .sequence(let sequence) = valueNode else {
                                throw ObsidianMetadataError.malformed("tags_must_be_list")
                            }
                            for item in sequence {
                                guard case .scalar(let scalar) = item else {
                                    throw ObsidianMetadataError.malformed("tag_must_be_text")
                                }
                                let raw = scalar.string
                                guard let canonical = canonicalTag(raw) else {
                                    throw ObsidianMetadataError.malformed("invalid_tag")
                                }
                                rawTags.append(ObsidianTag(
                                    name: raw.hasPrefix("#") ? String(raw.dropFirst()) : raw,
                                    canonical: canonical, origin: "frontmatter"))
                            }
                        }
                    }
                }
                state = "valid"
            } catch {
                // Keep the note searchable, but make bad YAML explicit rather
                // than returning a partial, misleading property index.
                properties.removeAll()
                scalars.removeAll()
                rawTags.removeAll()
                state = "invalid"
                diagnostic = String(describing: error).prefix(256).description
            }
        } else if invalidHeader != nil {
            state = "invalid"
        }

        rawTags += inlineTags(body)
        var unique: Set<String> = []
        let tags = rawTags.filter {
            unique.insert($0.canonical + ":" + $0.origin).inserted
        }
        return ObsidianMetadata(properties: properties, tags: tags, scalars: scalars,
                                state: state, diagnostic: diagnostic, body: body,
                                bodyLineOffset: bodyLineOffset)
    }

    private struct ScalarValue {
        let kind: String
        let text: String
    }

    private struct Converted {
        let kind: String
        let json: Any
        let items: [ScalarValue]?
    }

    private static func convert(_ node: Node, depth: Int) throws -> Converted {
        guard depth <= maximumDepth else { throw ObsidianMetadataError.resourceLimit }
        if case .scalar(let scalar) = node {
            let raw = scalar.string
            guard raw.utf8.count <= 64 * 1024 else { throw ObsidianMetadataError.resourceLimit }
            let tag = node.tag.rawValue
            let value: Any
            let kind: String
            switch tag {
            case Tag.Name.null.rawValue:
                value = NSNull(); kind = "null"
            case Tag.Name.bool.rawValue:
                value = raw.lowercased() == "true"; kind = "checkbox"
            case Tag.Name.int.rawValue:
                let stripped = raw.replacingOccurrences(of: "_", with: "")
                guard let integer = Int64(stripped) else {
                    throw ObsidianMetadataError.malformed("unsupported_integer")
                }
                value = integer; kind = "number"
            case Tag.Name.float.rawValue:
                let stripped = raw.replacingOccurrences(of: "_", with: "")
                guard let double = Double(stripped), double.isFinite else {
                    throw ObsidianMetadataError.malformed("unsupported_float")
                }
                value = double; kind = "number"
            case Tag.Name.timestamp.rawValue:
                // Preserve the original ISO date/time string, never adjust
                // its timezone or rewrite the user's YAML.
                value = raw
                kind = raw.contains("T") || raw.contains("t") || raw.contains(" ") ?
                    "datetime" : "date"
            case Tag.Name.str.rawValue:
                value = raw
                kind = "text"
            default:
                throw ObsidianMetadataError.malformed("unsupported_yaml_tag")
            }
            return Converted(kind: kind, json: value,
                             items: kind == "null" ? [] : [
                                ScalarValue(kind: kind, text: raw)
                             ])
        }
        if case .sequence(let sequence) = node {
            guard sequence.count <= maximumCollection else {
                throw ObsidianMetadataError.resourceLimit
            }
            let converted = try sequence.map { try convert($0, depth: depth + 1) }
            let atoms = converted.enumerated().flatMap { offset, child in
                child.items?.map { ScalarValue(kind: $0.kind, text: $0.text) } ?? []
            }
            return Converted(kind: "list", json: converted.map(\.json), items: atoms)
        }
        if case .mapping(let mapping) = node {
            guard mapping.count <= maximumCollection else {
                throw ObsidianMetadataError.resourceLimit
            }
            var object: [String: Any] = [:]
            for (keyNode, valueNode) in mapping {
                guard case .scalar(let key) = keyNode, object[key.string] == nil,
                      key.string.utf8.count <= 256 else {
                    throw ObsidianMetadataError.malformed("nested_invalid_key")
                }
                object[key.string] = try convert(valueNode, depth: depth + 1).json
            }
            return Converted(kind: "object", json: object, items: nil)
        }
        throw ObsidianMetadataError.malformed("yaml_alias_not_supported")
    }

    /// Obsidian recognizes tags in note text, not in code fences, inline
    /// code, HTML comments, escaped hashes, or URLs. Preserve original
    /// spelling for presentation while indexing case-folded hierarchy keys.
    public static func inlineTags(_ body: String) -> [ObsidianTag] {
        var result: [ObsidianTag] = []
        var fence: (Character, Int)?
        var inComment = false
        var inlineTicks = 0
        for line in body.components(separatedBy: "\n") {
            let prefix = line.prefix(while: { $0 == " " }).count
            let trimmed = prefix <= 3 ? String(line.dropFirst(prefix)) : line
            var structural = trimmed
            for _ in 0..<4 {
                guard structural.hasPrefix(">") else { break }
                structural.removeFirst()
                if structural.hasPrefix(" ") { structural.removeFirst() }
            }
            if let marker = fence {
                let count = structural.prefix(while: { $0 == marker.0 }).count
                if structural.first == marker.0, count >= marker.1,
                   structural.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                continue
            }
            if prefix >= 4 { continue }
            if let first = structural.first, first == "`" || first == "~" {
                let count = structural.prefix(while: { $0 == first }).count
                if count >= 3 { fence = (first, count); continue }
            }
            let characters = Array(line)
            var cursor = 0
            while cursor < characters.count {
                func begins(_ token: String, at index: Int) -> Bool {
                    let slice = Array(token)
                    return index + slice.count <= characters.count &&
                        Array(characters[index..<(index + slice.count)]) == slice
                }
                if inComment {
                    if begins("-->", at: cursor) { inComment = false; cursor += 3 }
                    else { cursor += 1 }
                    continue
                }
                if begins("<!--", at: cursor) {
                    inComment = true; cursor += 4; continue
                }
                if characters[cursor] == "\\" { cursor += min(2, characters.count - cursor); continue }
                if characters[cursor] == "`" {
                    var end = cursor
                    while end < characters.count && characters[end] == "`" { end += 1 }
                    let length = end - cursor
                    if inlineTicks == 0 { inlineTicks = length }
                    else if inlineTicks == length { inlineTicks = 0 }
                    cursor = end
                    continue
                }
                if inlineTicks > 0 { cursor += 1; continue }
                if begins("](", at: cursor) {
                    cursor += 2
                    var depth = 1
                    while cursor < characters.count && depth > 0 {
                        if characters[cursor] == "(" { depth += 1 }
                        if characters[cursor] == ")" { depth -= 1 }
                        cursor += 1
                    }
                    continue
                }
                if characters[cursor] == "<", cursor + 1 < characters.count {
                    let next = characters[cursor + 1]
                    if next.isLetter || next == "/" || next == "!" || next == "?" {
                        if let end = characters[(cursor+1)...].firstIndex(of: ">") {
                            cursor = end + 1; continue
                        }
                    }
                }
                if characters[cursor] != "#" { cursor += 1; continue }
                if cursor > 0 {
                    let before = characters[cursor-1]
                    if before.isLetter || before.isNumber || before == "_" ||
                       before == "/" || before == ":" || before == "#" {
                        cursor += 1; continue
                    }
                }
                var end = cursor + 1
                while end < characters.count &&
                    (characters[end].unicodeScalars.allSatisfy { scalar in
                        if scalar == "<" || scalar == ">" || scalar == "+" || scalar == "=" {
                            return false
                        }
                        switch scalar.properties.generalCategory {
                        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                             .modifierLetter, .otherLetter, .nonspacingMark,
                             .spacingMark, .enclosingMark, .decimalNumber,
                             .letterNumber, .otherNumber, .otherSymbol,
                             .modifierSymbol, .mathSymbol, .currencySymbol:
                            return true
                        default:
                            return scalar == "_" || scalar == "-" || scalar == "/" ||
                                   scalar == "\u{200D}"
                        }
                    }) {
                    end += 1
                }
                if end > cursor + 1 {
                    let name = String(characters[(cursor+1)..<end])
                    if let canonical = canonicalTag(name) {
                        result.append(ObsidianTag(name: name, canonical: canonical,
                                                  origin: "inline"))
                        cursor = end
                        continue
                    }
                }
                cursor += 1
            }
        }
        return result
    }
}
