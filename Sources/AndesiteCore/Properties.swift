import Foundation
import Yams

/// A YAML property value as Obsidian stores it.
public enum PropertyValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([String])
    /// An ISO 8601 date ("2024-05-01") or date and time ("2024-05-01T09:30"),
    /// written unquoted so it stays a date.
    case date(String)

    var yaml: Any {
        switch self {
        case .text(let value), .date(let value): return value
        case .number(let value): return value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .bool(let value): return value
        case .list(let value): return value
        }
    }

    /// The YAML lines for `name: value`.
    func rendered(as name: String) throws -> [String] {
        let yaml: String
        if case .date(let date) = self {
            guard date.range(of: #"^\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}(:?\d{2})?)?)?$"#,
                             options: .regularExpression) != nil else { throw VaultError.unsupported("invalid date") }
            yaml = try Yams.serialize(node: .mapping(Node.Mapping([(Node(name), Node(date, Tag(.timestamp), .plain))])), width: -1, allowUnicode: true)
        } else {
            yaml = try Yams.dump(object: [name: self.yaml], width: -1, allowUnicode: true)
        }
        return yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    }
}

/// Edits of a note's frontmatter as pure functions of its bytes, so an
/// editor can apply them to text it has not saved yet. Only the lines of
/// the property changed are rewritten; every other byte is kept. The
/// `VaultRuntime` methods of the same names apply them to the stored note.
public enum Frontmatter {
    /// Sets (or with `nil` removes) one property.
    public static func setting(_ name: String, to value: PropertyValue?, in content: Data) throws -> Data {
        try VaultRuntime.editFrontmatter(content, name: name, value: value)
    }

    /// Adds a tag to the `tags` property, unless it is already there.
    public static func addingTag(_ tag: String, to content: Data) throws -> Data {
        guard let canonical = ObsidianMetadataParser.canonicalTag(tag) else { throw VaultError.unsupported("invalid tag") }
        var tags = try propertyTags(content)
        if tags.contains(where: { ObsidianMetadataParser.canonicalTag($0) == canonical }) { return content }
        tags.append(tag.hasPrefix("#") ? String(tag.dropFirst()) : tag)
        return try setting("tags", to: .list(tags), in: content)
    }

    /// Removes a tag from the `tags` property. Tags written inline in the
    /// body (`#tag`) are prose and are left alone.
    public static func removingTag(_ tag: String, from content: Data) throws -> Data {
        let canonical = ObsidianMetadataParser.canonicalTag(tag)
        let tags = try propertyTags(content)
        let kept = tags.filter { ObsidianMetadataParser.canonicalTag($0) != canonical }
        if kept.count == tags.count { return content }
        return try setting("tags", to: kept.isEmpty ? nil : .list(kept), in: content)
    }

    private static func propertyTags(_ content: Data) throws -> [String] {
        let metadata = try ObsidianMetadataParser.parse(content)
        guard metadata.state != "invalid" else { throw VaultError.unsupported("the note's frontmatter is not valid YAML") }
        let tags = metadata.properties.first { ObsidianMetadataParser.canonicalProperty($0["name"] as? String ?? "") == "tags" }
        return (tags?["value"] as? [String]) ?? ((tags?["value"] as? String).map { [$0] } ?? [])
    }
}

extension VaultRuntime {
    /// Sets (or with `nil` removes) one frontmatter property. Only that
    /// property's lines change; every other byte of the note is kept.
    @discardableResult
    public func setProperty(_ path: String, _ name: String, to value: PropertyValue?, revision: Data) throws -> IndexedDocument {
        try editNote(path, revision: revision) { try Frontmatter.setting(name, to: value, in: $0) }
    }

    /// Adds a tag to the note's `tags` property (if not already tagged there).
    @discardableResult
    public func addTag(_ path: String, _ tag: String, revision: Data) throws -> IndexedDocument {
        try editNote(path, revision: revision) { try Frontmatter.addingTag(tag, to: $0) }
    }

    /// Removes a tag from the note's `tags` property. Tags written inline in
    /// the body (`#tag`) are prose and are left alone.
    @discardableResult
    public func removeTag(_ path: String, _ tag: String, revision: Data) throws -> IndexedDocument {
        try editNote(path, revision: revision) { try Frontmatter.removingTag(tag, from: $0) }
    }

    /// Applies `edit` to the current note and saves the result if `revision`
    /// is still current (an unchanged note is not saved again).
    private func editNote(_ path: String, revision: Data, _ edit: (Data) throws -> Data) throws -> IndexedDocument {
        let (document, content) = try read(path)
        guard document.kind == "markdown" else { throw VaultError.unsupported("properties belong to Markdown notes") }
        let edited = try edit(content)
        if edited == content { return document }
        return try update(path, edited, revision: revision)
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
        let rendered = try value?.rendered(as: name) ?? []
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
