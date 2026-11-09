import Foundation

public enum ObsidianIndexError: Error, Equatable {
    case invalidQuery
    case inconsistentIndex
}

public struct ObsidianFilter: Sendable {
    public let tag: String?
    public let property: String?
    public let value: String?

    public init(tag: String? = nil, property: String? = nil, value: String? = nil) throws {
        if let tag {
            guard ObsidianMetadataParser.canonicalTag(tag) != nil else {
                throw ObsidianIndexError.invalidQuery
            }
        }
        if let property {
            guard !property.isEmpty, property.utf8.count <= 256,
                  !property.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .control
                  }) else { throw ObsidianIndexError.invalidQuery }
        }
        guard value == nil || property != nil,
              value == nil || value!.utf8.count <= 1024 else {
            throw ObsidianIndexError.invalidQuery
        }
        self.tag = tag.flatMap(ObsidianMetadataParser.canonicalTag)
        self.property = property.map(ObsidianMetadataParser.canonicalProperty)
        self.value = value.map(ObsidianMetadataParser.canonicalProperty)
    }

    /// A fragment attached to an alias 'e' for indexed live entries.
    /// Input strings are always bound parameters, never interpolated as SQL.
    public var sql: String {
        var result = ""
        if tag != nil {
            result += """
             AND EXISTS (
                SELECT 1 FROM document_tags t
                WHERE t.vault_id=e.vault_id AND t.entry_id=e.id
                  AND t.indexed_revision=e.head_revision
                  AND (t.canonical=? OR substr(t.canonical,1,length(?)+1)=? || '/')
             )
            """
        }
        if property != nil {
            result += """
             AND EXISTS (
                SELECT 1 FROM document_property_keys k
                WHERE k.vault_id=e.vault_id AND k.entry_id=e.id
                  AND k.indexed_revision=e.head_revision AND k.name_key=?
             )
            """
        }
        if value != nil {
            result += """
             AND EXISTS (
                SELECT 1 FROM document_property_values v
                WHERE v.vault_id=e.vault_id AND v.entry_id=e.id
                  AND v.indexed_revision=e.head_revision
                  AND v.name_key=? AND v.value_text=?
             )
            """
        }
        return result
    }

    public var bindings: [SQLiteValue] {
        var result: [SQLiteValue] = []
        if let tag { result += [.text(tag), .text(tag), .text(tag)] }
        if let property { result.append(.text(property)) }
        if let property, let value { result += [.text(property), .text(value)] }
        return result
    }
}

/// A frontmatter value as indexed: YAML scalars, lists and maps.
public enum MetadataValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case text(String)
    case list([MetadataValue])
    case map([String: MetadataValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .text(value) }
        else if let value = try? c.decode([MetadataValue].self) { self = .list(value) }
        else { self = .map(try c.decode([String: MetadataValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .text(let value): try c.encode(value)
        case .list(let value): try c.encode(value)
        case .map(let value): try c.encode(value)
        }
    }
}

/// One frontmatter property. `type` is Obsidian's: text, number,
/// checkbox, date, datetime, list, tags, null.
public struct NoteProperty: Sendable, Equatable, Codable {
    public let name: String
    public let type: String
    public let value: MetadataValue
}

public struct NoteTag: Sendable, Equatable, Codable {
    public let tag: String
    public let canonical: String
    /// Where the tag was found: "frontmatter" or "inline" (a #tag in the text).
    public let origin: String
}

/// A note's indexed frontmatter. `state` is "valid", "absent" or
/// "invalid" (then `diagnostic` says why and `properties` is empty).
public struct NoteMetadata: Sendable, Equatable, Encodable {
    public let state: String
    public let properties: [NoteProperty]
    public let tags: [NoteTag]
    public let diagnostic: String?

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(properties, forKey: .properties)
        try c.encode(tags, forKey: .tags)
        try c.encode(diagnostic, forKey: .diagnostic)
    }
    private enum CodingKeys: String, CodingKey { case state, properties, tags, diagnostic }
}

public struct TagSummary: Sendable, Equatable, Codable {
    public let tag: String
    public let canonical: String
    public let documents: Int
}

public struct PropertySummary: Sendable, Equatable, Codable {
    public let key: String
    public let canonical: String
    /// The value types seen across notes; more than one is a conflict.
    public let types: [String]
    public let typeConflict: Bool
    public let documents: Int
}

public struct TagPage: Sendable, Equatable, Encodable {
    public let tags: [TagSummary]
    public let total: Int
    public let offset: Int
    public let nextOffset: Int?

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tags, forKey: .tags)
        try c.encode(total, forKey: .total)
        try c.encode(offset, forKey: .offset)
        try c.encode(nextOffset, forKey: .nextOffset)
    }
    private enum CodingKeys: String, CodingKey { case tags, total, offset, nextOffset }
}

public struct PropertyPage: Sendable, Equatable, Encodable {
    public let properties: [PropertySummary]
    public let total: Int
    public let offset: Int
    public let nextOffset: Int?

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(properties, forKey: .properties)
        try c.encode(total, forKey: .total)
        try c.encode(offset, forKey: .offset)
        try c.encode(nextOffset, forKey: .nextOffset)
    }
    private enum CodingKeys: String, CodingKey { case properties, total, offset, nextOffset }
}

public enum ObsidianMetadataIndex {
    private static let validLive = """
        JOIN entries e ON e.vault_id=x.vault_id AND e.id=x.entry_id
        JOIN document_metadata m ON m.vault_id=e.vault_id AND m.entry_id=e.id
          AND m.indexed_revision=e.head_revision
        WHERE x.vault_id=? AND e.state='live' AND e.kind='markdown'
          AND x.indexed_revision=e.head_revision
          AND NOT EXISTS (
            SELECT 1 FROM incidents i WHERE i.vault_id=e.vault_id
            AND i.status='open'
            AND (i.entry_id=e.id OR (i.entry_id IS NULL AND i.path_key=e.path_key))
          )
        """

    public static func document(db: SQLiteConnection, vaultID: Data,
                                id: Data, revision: Data) throws -> NoteMetadata {
        guard id.count == 16, revision.count == 16 else {
            throw ObsidianIndexError.invalidQuery
        }
        let rows = try db.queryValues("""
            SELECT state,properties_json,diagnostic
            FROM document_properties WHERE vault_id=? AND entry_id=?
              AND indexed_revision=?
            """, bindings: [.blob(vaultID), .blob(id), .blob(revision)])
        guard rows.count == 1, case .text(let state) = rows[0][0],
              case .text(let payload) = rows[0][1],
              let properties = try? JSONDecoder().decode([NoteProperty].self, from: Data(payload.utf8))
        else { throw ObsidianIndexError.inconsistentIndex }
        let tags = try db.queryValues("""
            SELECT display,canonical,origin
            FROM document_tags
            WHERE vault_id=? AND entry_id=? AND indexed_revision=?
            ORDER BY canonical,origin
            """, bindings: [.blob(vaultID), .blob(id), .blob(revision)]).map { item in
            guard case .text(let tag) = item[0], case .text(let canonical) = item[1],
                  case .text(let origin) = item[2] else { throw ObsidianIndexError.inconsistentIndex }
            return NoteTag(tag: tag, canonical: canonical, origin: origin)
        }
        let diagnostic: String?
        switch rows[0][2] {
        case .text(let error): diagnostic = error
        case .null: diagnostic = nil
        default: throw ObsidianIndexError.inconsistentIndex
        }
        return NoteMetadata(state: state, properties: properties, tags: tags, diagnostic: diagnostic)
    }

    public static func tags(db: SQLiteConnection, vaultID: Data,
                            limit: Int, offset: Int) throws -> TagPage {
        guard (1...100).contains(limit), (0...100_000).contains(offset) else {
            throw ObsidianIndexError.invalidQuery
        }
        let total = try count(db, "SELECT x.canonical FROM document_tags x \(validLive) GROUP BY x.canonical", vaultID)
        let tags = try db.queryValues("""
            SELECT x.canonical, min(x.display), count(DISTINCT x.entry_id)
            FROM document_tags x \(validLive)
            GROUP BY x.canonical ORDER BY x.canonical
            LIMIT ? OFFSET ?
            """, bindings: [.blob(vaultID), .integer(Int64(limit)), .integer(Int64(offset))]).map { row in
            guard case .text(let key) = row[0], case .text(let display) = row[1],
                  case .integer(let count) = row[2] else { throw ObsidianIndexError.inconsistentIndex }
            return TagSummary(tag: display, canonical: key, documents: Int(count))
        }
        return TagPage(tags: tags, total: total, offset: offset,
                       nextOffset: offset + tags.count < total ? offset + tags.count : nil)
    }

    public static func properties(db: SQLiteConnection, vaultID: Data,
                                  limit: Int, offset: Int) throws -> PropertyPage {
        guard (1...100).contains(limit), (0...100_000).contains(offset) else {
            throw ObsidianIndexError.invalidQuery
        }
        let total = try count(db, "SELECT x.name_key FROM document_property_keys x \(validLive) GROUP BY x.name_key", vaultID)
        let properties = try db.queryValues("""
            SELECT x.name_key,min(x.display),group_concat(DISTINCT x.kind),
                   count(DISTINCT x.entry_id)
            FROM document_property_keys x \(validLive)
            GROUP BY x.name_key ORDER BY x.name_key
            LIMIT ? OFFSET ?
            """, bindings: [.blob(vaultID), .integer(Int64(limit)), .integer(Int64(offset))]).map { row in
            guard case .text(let key) = row[0], case .text(let display) = row[1],
                  case .text(let kinds) = row[2], case .integer(let count) = row[3] else {
                throw ObsidianIndexError.inconsistentIndex
            }
            let types = kinds.split(separator: ",").map(String.init).sorted()
            return PropertySummary(key: display, canonical: key, types: types,
                                   typeConflict: types.count > 1, documents: Int(count))
        }
        return PropertyPage(properties: properties, total: total, offset: offset,
                            nextOffset: offset + properties.count < total ? offset + properties.count : nil)
    }

    private static func count(_ db: SQLiteConnection, _ grouped: String, _ vaultID: Data) throws -> Int {
        guard case .integer(let total) = try db.queryValues("SELECT count(*) FROM (\(grouped))",
                                                          bindings: [.blob(vaultID)]).first?.first,
              total >= 0 else { throw ObsidianIndexError.inconsistentIndex }
        return Int(total)
    }
}
