import Foundation
import Yams

/// A YAML property value as Obsidian stores it.
public enum PropertyValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([String])

    var yaml: Any {
        switch self {
        case .text(let value): return value
        case .number(let value): return value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .bool(let value): return value
        case .list(let value): return value
        }
    }
}

extension VaultRuntime {
    /// Sets (or with `nil` removes) one frontmatter property. Only that
    /// property's lines change; every other byte of the note is kept.
    @discardableResult
    public func setProperty(_ path: String, _ name: String, to value: PropertyValue?, revision: Data) throws -> IndexedDocument {
        let (document, content) = try read(path)
        guard document.kind == "markdown" else { throw VaultError.unsupported("properties belong to Markdown notes") }
        let edited = try Self.editFrontmatter(content, name: name, value: value)
        if edited == content { return document }
        return try update(path, edited, revision: revision)
    }

    /// Adds a tag to the note's `tags` property (if not already tagged there).
    @discardableResult
    public func addTag(_ path: String, _ tag: String, revision: Data) throws -> IndexedDocument {
        guard let canonical = ObsidianMetadataParser.canonicalTag(tag) else { throw VaultError.unsupported("invalid tag") }
        var tags = try propertyTags(path)
        if tags.contains(where: { ObsidianMetadataParser.canonicalTag($0) == canonical }) { return try document(path) }
        tags.append(tag.hasPrefix("#") ? String(tag.dropFirst()) : tag)
        return try setProperty(path, "tags", to: .list(tags), revision: revision)
    }

    /// Removes a tag from the note's `tags` property. Tags written inline in
    /// the body (`#tag`) are prose and are left alone.
    @discardableResult
    public func removeTag(_ path: String, _ tag: String, revision: Data) throws -> IndexedDocument {
        let canonical = ObsidianMetadataParser.canonicalTag(tag)
        let tags = try propertyTags(path)
        let kept = tags.filter { ObsidianMetadataParser.canonicalTag($0) != canonical }
        if kept.count == tags.count { return try document(path) }
        return try setProperty(path, "tags", to: kept.isEmpty ? nil : .list(kept), revision: revision)
    }

    private func propertyTags(_ path: String) throws -> [String] {
        let metadata = try ObsidianMetadataParser.parse(read(path).content)
        guard metadata.state != "invalid" else { throw VaultError.unsupported("the note's frontmatter is not valid YAML") }
        let tags = metadata.properties.first { ObsidianMetadataParser.canonicalProperty($0["name"] as? String ?? "") == "tags" }
        return (tags?["value"] as? [String]) ?? ((tags?["value"] as? String).map { [$0] } ?? [])
    }

    /// Replaces the lines of one top-level frontmatter key (the key line and
    /// its indented or list continuation lines), inserting the key or the
    /// whole frontmatter block if absent.
    static func editFrontmatter(_ content: Data, name: String, value: PropertyValue?) throws -> Data {
        guard let text = String(data: content, encoding: .utf8) else { throw VaultError.unsupported("Markdown must be valid UTF-8") }
        guard !name.isEmpty, !name.contains("\n"), name.trimmingCharacters(in: .whitespaces) == name else {
            throw VaultError.unsupported("invalid property name")
        }
        guard try ObsidianMetadataParser.parse(content).state != "invalid" else {
            throw VaultError.unsupported("the note's frontmatter is not valid YAML")
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.lines().map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let rendered = try value.map { value -> [String] in
            let yaml = try Yams.dump(object: [name: value.yaml], width: -1, allowUnicode: true)
            return yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        } ?? []
        let key = ObsidianMetadataParser.canonicalProperty(name)
        if lines.first == "---", let close = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            var start: Int?
            for index in 1..<close {
                let line = lines[index]
                guard let first = line.first, first != " ", first != "\t", first != "#", first != "-",
                      let colon = line.firstIndex(of: ":") else { continue }
                var raw = line[..<colon].trimmingCharacters(in: .whitespaces)
                if raw.count >= 2, let q = raw.first, q == "\"" || q == "'", raw.last == q { raw = String(raw.dropFirst().dropLast()) }
                if ObsidianMetadataParser.canonicalProperty(raw) == key { start = index; break }
            }
            if let start {
                var end = start + 1
                while end < close, lines[end].isEmpty || lines[end].first == " " || lines[end].first == "\t" || lines[end].first == "-" { end += 1 }
                lines.replaceSubrange(start..<end, with: rendered)
            } else {
                lines.insert(contentsOf: rendered, at: close)
            }
        } else if !rendered.isEmpty {
            lines.insert(contentsOf: ["---"] + rendered + ["---"], at: 0)
        }
        let result = Data(lines.joined(separator: newline).utf8)
        // Never write a note whose properties no longer parse.
        guard try ObsidianMetadataParser.parse(result).state != "invalid" else { throw VaultError.unsupported("edited frontmatter would be invalid") }
        return result
    }
}
