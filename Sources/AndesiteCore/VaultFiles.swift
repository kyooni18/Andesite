import Foundation

/// A live file of the vault, note or not, with when it was first and last
/// recorded. Dates come from the revision history (for a file synced from
/// elsewhere, when this vault recorded it).
public struct VaultFile: Equatable, Sendable {
    public let id: Data
    public let path: String
    /// "markdown" or "attachment".
    public let kind: String
    public let byteLength: Int
    public let created: Date
    public let modified: Date
}

extension VaultRuntime {
    /// Every live file, notes and attachments, in path order.
    public func files() throws -> [VaultFile] {
        let r = try requireReady()
        let rows = try r.db.queryValues("""
            SELECT e.id,e.path,e.kind,h.byte_length,
                   (SELECT min(created_at) FROM revisions WHERE vault_id=e.vault_id AND entry_id=e.id),
                   h.created_at
            FROM entries e JOIN revisions h ON h.vault_id=e.vault_id AND h.revision_id=e.head_revision AND h.deleted=0
            WHERE e.vault_id=? AND e.state='live' ORDER BY e.path
            """, bindings: [.blob(vaultID)])
        let format = ISO8601DateFormatter()
        return try rows.map { row in
            guard case .blob(let id) = row[0], case .text(let path) = row[1], case .text(let kind) = row[2],
                  case .integer(let size) = row[3], case .text(let first) = row[4], case .text(let last) = row[5],
                  let created = format.date(from: first), let modified = format.date(from: last) else {
                throw VaultRuntimeError.inconsistentCatalog
            }
            return VaultFile(id: id, path: path, kind: kind, byteLength: Int(size), created: created, modified: modified)
        }
    }
}

extension Vault {
    public func files() async throws -> [VaultFile] {
        try await perform(.read) { try $0.files() }
    }
}
