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
                                id: Data, revision: Data) throws -> [String: Any] {
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
              let bytes = payload.data(using: .utf8),
              let values = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]
        else { throw ObsidianIndexError.inconsistentIndex }
        let tags = try db.queryValues("""
            SELECT canonical,display,origin
            FROM document_tags
            WHERE vault_id=? AND entry_id=? AND indexed_revision=?
            ORDER BY canonical,origin
            """, bindings: [.blob(vaultID), .blob(id), .blob(revision)])
        let displayedTags: [[String: String]] = try tags.map { item in
            guard item.count == 3,
                  case .text(let key) = item[0],
                  case .text(let label) = item[1],
                  case .text(let origin) = item[2] else {
                throw ObsidianIndexError.inconsistentIndex
            }
            return ["tag": label, "canonical": key, "origin": origin]
        }
        let diagnostic: Any
        if case .text(let error) = rows[0][2] { diagnostic = error }
        else if rows[0][2] == .null { diagnostic = NSNull() }
        else { throw ObsidianIndexError.inconsistentIndex }
        return ["state": state, "properties": values,
                "tags": displayedTags, "diagnostic": diagnostic]
    }

    public static func tags(db: SQLiteConnection, vaultID: Data,
                            limit: Int, offset: Int) throws -> [String: Any] {
        guard (1...100).contains(limit), (0...100_000).contains(offset) else {
            throw ObsidianIndexError.invalidQuery
        }
        let countRows = try db.queryValues("""
            SELECT count(*) FROM (
              SELECT x.canonical FROM document_tags x
              \(validLive)
              GROUP BY x.canonical
            )
            """, bindings: [.blob(vaultID)])
        guard case .integer(let total) = countRows.first?.first,
              total >= 0 else { throw ObsidianIndexError.inconsistentIndex }
        let records = try db.queryValues("""
            SELECT x.canonical, min(x.display), count(DISTINCT x.entry_id)
            FROM document_tags x \(validLive)
            GROUP BY x.canonical ORDER BY x.canonical
            LIMIT ? OFFSET ?
            """, bindings: [.blob(vaultID), .integer(Int64(limit)),
                             .integer(Int64(offset))])
        let values: [[String: Any]] = try records.map { row in
            guard case .text(let key) = row[0],
                  case .text(let display) = row[1],
                  case .integer(let count) = row[2] else {
                throw ObsidianIndexError.inconsistentIndex
            }
            return ["tag": display, "canonical": key, "documents": count]
        }
        return ["tags": values, "total": total, "offset": offset,
                "nextOffset": Int64(offset + values.count) < total ?
                    (offset + values.count) as Any : NSNull()]
    }

    public static func properties(db: SQLiteConnection, vaultID: Data,
                                  limit: Int, offset: Int) throws -> [String: Any] {
        guard (1...100).contains(limit), (0...100_000).contains(offset) else {
            throw ObsidianIndexError.invalidQuery
        }
        let countRows = try db.queryValues("""
            SELECT count(*) FROM (
              SELECT x.name_key FROM document_property_keys x \(validLive)
              GROUP BY x.name_key
            )
            """, bindings: [.blob(vaultID)])
        guard case .integer(let total) = countRows.first?.first,
              total >= 0 else { throw ObsidianIndexError.inconsistentIndex }
        let records = try db.queryValues("""
            SELECT x.name_key,min(x.display),group_concat(DISTINCT x.kind),
                   count(DISTINCT x.entry_id)
            FROM document_property_keys x \(validLive)
            GROUP BY x.name_key ORDER BY x.name_key
            LIMIT ? OFFSET ?
            """, bindings: [.blob(vaultID), .integer(Int64(limit)),
                             .integer(Int64(offset))])
        let values: [[String: Any]] = try records.map { row in
            guard case .text(let key) = row[0],
                  case .text(let display) = row[1],
                  case .text(let kinds) = row[2],
                  case .integer(let count) = row[3] else {
                throw ObsidianIndexError.inconsistentIndex
            }
            let observed = kinds.split(separator: ",").map(String.init).sorted()
            return ["key": display, "canonical": key, "types": observed,
                    "typeConflict": observed.count > 1, "documents": count]
        }
        return ["properties": values, "total": total, "offset": offset,
                "nextOffset": Int64(offset + values.count) < total ?
                    (offset + values.count) as Any : NSNull()]
    }
}
