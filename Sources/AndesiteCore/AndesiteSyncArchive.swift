import Foundation

public enum AndesiteSyncError: Error, Equatable {
    case invalidPacket
    case unsupportedVersion
    case historyGap
    case sequenceConflict
    case contentMismatch
    case artifactTooLarge
    case invalidPeer
}

public struct AndesiteSyncChange: Codable, Sendable, Equatable {
    public let sequence: Int64
    /// Exact source event (including revision/operation identifiers), never
    /// a command that can mutate this receiver's active Vault.
    public let eventJSON: String
    public let contentSHA256: String?
    public let contentBase64: String?
}

public struct AndesiteSyncChangeBatch: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let sourceVault: String
    public let sourceEpoch: String
    public let after: Int64
    public let changes: [AndesiteSyncChange]
    public let headSequence: Int64

    public var through: Int64 { changes.last?.sequence ?? after }
}

public struct AndesiteSyncSnapshot: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let sourceVault: String
    public let sourceEpoch: String
    public let id: String
    public let document: String
    public let revision: String
    public let originalPath: String
    public let contentSHA256: String
    public let contentBase64: String
    public let byteLength: Int
    public let reason: String
    public let createdAt: TimeInterval
    public let expiresAt: TimeInterval
}

public struct AndesiteSyncReceipt: Codable, Sendable, Equatable {
    public let sourceVault: String
    public let sourceEpoch: String
    public let acknowledgedSequence: Int64
    public let accepted: Int
    public let replay: Bool
}

/// Pure wire-level contract shared by the app and standalone API server.
/// No filesystem objects or database handles escape into the transport.
public enum AndesiteSyncWire {
    public static let maximumJSONBytes = 256 * 1024
    public static let maximumObjectBytes = 128 * 1024
    public static let maximumChangesPerBatch = 16

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard bytes.count <= maximumJSONBytes else { throw AndesiteSyncError.artifactTooLarge }
        return bytes
    }

    public static func decode<T: Decodable>(_ type: T.Type, bytes: Data) throws -> T {
        guard bytes.count <= maximumJSONBytes else { throw AndesiteSyncError.artifactTooLarge }
        do { return try JSONDecoder().decode(T.self, from: bytes) }
        catch { throw AndesiteSyncError.invalidPacket }
    }

    static func identifier(_ hex: String, bytes: Int) -> Data? {
        guard hex.utf8.count == bytes * 2, hex.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        var parsed = [UInt8]()
        parsed.reserveCapacity(bytes)
        for offset in stride(from: 0, to: hex.utf8.count, by: 2) {
            let items = Array(hex.utf8)
            guard let digit = UInt8(String(decoding: items[offset..<(offset + 2)],
                                           as: UTF8.self), radix: 16) else { return nil }
            parsed.append(digit)
        }
        return Data(parsed)
    }

    static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func validateEvent(_ change: AndesiteSyncChange) throws -> Data? {
        guard change.sequence > 0, change.eventJSON.utf8.count <= 4096,
              let bytes = change.eventJSON.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              event["sequence"] as? String == String(change.sequence),
              let document = event["entryId"] as? String,
              UUID(uuidString: document) != nil,
              let revision = event["revision"] as? String,
              UUID(uuidString: revision) != nil,
              let type = event["type"] as? String,
              !type.isEmpty, type.utf8.count <= 64
        else { throw AndesiteSyncError.invalidPacket }
        switch (change.contentSHA256, change.contentBase64) {
        case (nil, nil):
            guard event["contentHash"] is NSNull else {
                throw AndesiteSyncError.contentMismatch
            }
            return nil
        case (let digest?, let base64?):
            guard let expected = identifier(digest, bytes: 32),
                  let bytes = Data(base64Encoded: base64),
                  bytes.count <= maximumObjectBytes,
                  let eventHash = event["contentHash"] as? String,
                  eventHash == digest,
                  ObjectStore.hash(bytes) == hex(expected),
                  event["size"] as? String == String(bytes.count) else {
                throw AndesiteSyncError.contentMismatch
            }
            return bytes
        default:
            throw AndesiteSyncError.invalidPacket
        }
    }

    static func validateSnapshot(_ snapshot: AndesiteSyncSnapshot) throws -> Data {
        guard snapshot.protocolVersion == 1,
              identifier(snapshot.sourceVault, bytes: 16) != nil,
              identifier(snapshot.sourceEpoch, bytes: 16) != nil,
              identifier(snapshot.id, bytes: 16) != nil,
              identifier(snapshot.document, bytes: 16) != nil,
              identifier(snapshot.revision, bytes: 16) != nil,
              identifier(snapshot.contentSHA256, bytes: 32) != nil,
              snapshot.byteLength >= 0, snapshot.byteLength <= maximumObjectBytes,
              snapshot.originalPath.utf8.count <= 4096,
              !snapshot.originalPath.hasPrefix("/"), !snapshot.originalPath.contains(".."),
              !snapshot.originalPath.contains("\0"),
              snapshot.createdAt.isFinite, snapshot.expiresAt.isFinite,
              snapshot.expiresAt > snapshot.createdAt,
              snapshot.reason.utf8.count <= 64,
              let bytes = Data(base64Encoded: snapshot.contentBase64),
              bytes.count == snapshot.byteLength,
              ObjectStore.hash(bytes) == snapshot.contentSHA256 else {
            throw AndesiteSyncError.contentMismatch
        }
        return bytes
    }
}

/// Single SQLite owner only. Replication inbox rows are *archives*, not
/// active note revisions. Applying remote content requires a later explicit
/// conflict-aware reconciliation protocol.
enum AndesiteSyncArchive {
    static func epoch(db: SQLiteConnection, vaultID: Data) throws -> Data {
        let rows = try db.queryValues("SELECT epoch FROM vaults WHERE id=?",
                                      bindings: [.blob(vaultID)])
        guard rows.count == 1, case .blob(let bytes) = rows[0][0],
              bytes.count == 16 else { throw AndesiteSyncError.invalidPacket }
        return bytes
    }

    static func outgoingChanges(db: SQLiteConnection, objects: ObjectStore,
                                vaultID: Data, after: Int64, limit: Int) throws
        -> AndesiteSyncChangeBatch {
        guard after >= 0, (1...AndesiteSyncWire.maximumChangesPerBatch).contains(limit)
        else { throw AndesiteSyncError.invalidPacket }
        let state = try db.queryValues("SELECT min_seq,next_seq FROM vaults WHERE id=?",
                                       bindings: [.blob(vaultID)])
        guard state.count == 1, state[0].count == 2,
              case .integer(let minimum) = state[0][0],
              case .integer(let next) = state[0][1],
              next > 0, after >= minimum, after < next else {
            throw AndesiteSyncError.historyGap
        }
        let rows = try db.queryValues("""
            SELECT c.seq,c.payload_json,
                   CASE WHEN r.deleted=0 THEN lower(hex(r.content_hash)) ELSE NULL END,
                   r.byte_length
            FROM changes c LEFT JOIN revisions r
              ON r.vault_id=c.vault_id AND r.revision_id=c.revision_id
            WHERE c.vault_id=? AND c.seq>? ORDER BY c.seq LIMIT ?
            """, bindings: [.blob(vaultID), .integer(after), .integer(Int64(limit))])
        let source = AndesiteSyncWire.hex(vaultID)
        let originEpoch = AndesiteSyncWire.hex(try epoch(db: db, vaultID: vaultID))
        var events: [AndesiteSyncChange] = []
        for row in rows {
            guard row.count == 4, case .integer(let seq) = row[0],
                  seq == after + Int64(events.count) + 1,
                  case .text(let event) = row[1] else {
                throw AndesiteSyncError.historyGap
            }
            let digest: String?
            let content: String?
            if case .text(let hash) = row[2] {
                guard case .integer(let size) = row[3], size >= 0,
                      size <= AndesiteSyncWire.maximumObjectBytes else {
                    throw AndesiteSyncError.artifactTooLarge
                }
                let bytes = try objects.get(hash, maximumBytes: Int(size))
                guard bytes.count == Int(size), ObjectStore.hash(bytes) == hash else {
                    throw AndesiteSyncError.contentMismatch
                }
                digest = hash
                content = bytes.base64EncodedString()
            } else {
                digest = nil
                content = nil
            }
            let candidate = AndesiteSyncChange(sequence: seq, eventJSON: event,
                                               contentSHA256: digest,
                                               contentBase64: content)
            _ = try AndesiteSyncWire.validateEvent(candidate)
            let probe = AndesiteSyncChangeBatch(
                protocolVersion: 1, sourceVault: source, sourceEpoch: originEpoch,
                after: after, changes: events + [candidate], headSequence: next - 1)
            do { _ = try AndesiteSyncWire.encode(probe) }
            catch AndesiteSyncError.artifactTooLarge {
                if events.isEmpty { throw AndesiteSyncError.artifactTooLarge }
                break
            }
            events.append(candidate)
        }
        return AndesiteSyncChangeBatch(protocolVersion: 1, sourceVault: source,
                                       sourceEpoch: originEpoch, after: after,
                                       changes: events, headSequence: next - 1)
    }

    static func outgoingSnapshot(db: SQLiteConnection, objects: ObjectStore,
                                 vaultID: Data, snapshot: RecoverySnapshot) throws
        -> AndesiteSyncSnapshot {
        guard snapshot.byteLength <= AndesiteSyncWire.maximumObjectBytes else {
            throw AndesiteSyncError.artifactTooLarge
        }
        let bytes = try objects.get(snapshot.contentHash,
                                    maximumBytes: snapshot.byteLength)
        guard bytes.count == snapshot.byteLength,
              ObjectStore.hash(bytes) == snapshot.contentHash else {
            throw AndesiteSyncError.contentMismatch
        }
        let artifact = AndesiteSyncSnapshot(
            protocolVersion: 1, sourceVault: AndesiteSyncWire.hex(vaultID),
            sourceEpoch: AndesiteSyncWire.hex(try epoch(db: db, vaultID: vaultID)),
            id: AndesiteSyncWire.hex(snapshot.id),
            document: AndesiteSyncWire.hex(snapshot.entryID),
            revision: AndesiteSyncWire.hex(snapshot.revisionID),
            originalPath: snapshot.originalPath, contentSHA256: snapshot.contentHash,
            contentBase64: bytes.base64EncodedString(), byteLength: snapshot.byteLength,
            reason: snapshot.reason, createdAt: snapshot.createdAt.timeIntervalSince1970,
            expiresAt: snapshot.expiresAt.timeIntervalSince1970)
        _ = try AndesiteSyncWire.encode(artifact)
        return artifact
    }

    static func acceptChanges(db: SQLiteConnection,
                              batch: AndesiteSyncChangeBatch) throws -> AndesiteSyncReceipt {
        guard batch.protocolVersion == 1 else { throw AndesiteSyncError.unsupportedVersion }
        guard let source = AndesiteSyncWire.identifier(batch.sourceVault, bytes: 16),
              let epoch = AndesiteSyncWire.identifier(batch.sourceEpoch, bytes: 16),
              batch.after >= 0, batch.headSequence >= batch.after,
              !batch.changes.isEmpty,
              batch.changes.count <= AndesiteSyncWire.maximumChangesPerBatch,
              batch.through <= batch.headSequence else {
            throw AndesiteSyncError.invalidPacket
        }
        _ = try AndesiteSyncWire.encode(batch)
        var content: [Data?] = []
        for (index, change) in batch.changes.enumerated() {
            guard change.sequence == batch.after + Int64(index) + 1 else {
                throw AndesiteSyncError.historyGap
            }
            content.append(try AndesiteSyncWire.validateEvent(change))
        }
        return try db.transaction {
            let prior = try db.queryValues("""
                SELECT last_seq FROM sync_inbox_cursors
                WHERE origin_vault=? AND origin_epoch=?
                """, bindings: [.blob(source), .blob(epoch)])
            let cursor: Int64
            if prior.isEmpty { cursor = 0 }
            else if prior.count == 1, case .integer(let value) = prior[0][0] {
                cursor = value
            } else { throw AndesiteSyncError.invalidPacket }
            if cursor >= batch.through {
                for item in batch.changes {
                    let old = try db.queryValues("""
                        SELECT event_json,content_hash,content_bytes
                        FROM sync_inbox_changes
                        WHERE origin_vault=? AND origin_epoch=? AND seq=?
                        """, bindings: [.blob(source), .blob(epoch),
                                       .integer(item.sequence)])
                    guard old.count == 1, case .text(let json) = old[0][0],
                          json == item.eventJSON,
                          old[0][1] == item.contentSHA256.map(SQLiteValue.text) ?? .null,
                          old[0][2] == item.contentBase64.flatMap({ Data(base64Encoded: $0) })
                              .map(SQLiteValue.blob) ?? .null else {
                        throw AndesiteSyncError.sequenceConflict
                    }
                }
                return AndesiteSyncReceipt(sourceVault: batch.sourceVault,
                                           sourceEpoch: batch.sourceEpoch,
                                           acknowledgedSequence: batch.through,
                                           accepted: 0, replay: true)
            }
            guard cursor == batch.after else { throw AndesiteSyncError.historyGap }
            for (index, item) in batch.changes.enumerated() {
                try db.executeValues("""
                    INSERT INTO sync_inbox_changes(
                        origin_vault,origin_epoch,seq,event_json,content_hash,content_bytes
                    ) VALUES(?,?,?,?,?,?)
                    """, bindings: [.blob(source), .blob(epoch),
                                     .integer(item.sequence), .text(item.eventJSON),
                                     item.contentSHA256.map(SQLiteValue.text) ?? .null,
                                     content[index].map(SQLiteValue.blob) ?? .null])
            }
            try db.executeValues("""
                INSERT INTO sync_inbox_cursors(origin_vault,origin_epoch,last_seq)
                VALUES(?,?,?)
                ON CONFLICT(origin_vault,origin_epoch) DO UPDATE
                SET last_seq=excluded.last_seq
                """, bindings: [.blob(source), .blob(epoch), .integer(batch.through)])
            return AndesiteSyncReceipt(sourceVault: batch.sourceVault,
                                       sourceEpoch: batch.sourceEpoch,
                                       acknowledgedSequence: batch.through,
                                       accepted: batch.changes.count, replay: false)
        }
    }

    static func acceptSnapshot(db: SQLiteConnection,
                               snapshot: AndesiteSyncSnapshot) throws -> Bool {
        let bytes = try AndesiteSyncWire.validateSnapshot(snapshot)
        guard let source = AndesiteSyncWire.identifier(snapshot.sourceVault, bytes: 16),
              let epoch = AndesiteSyncWire.identifier(snapshot.sourceEpoch, bytes: 16),
              let id = AndesiteSyncWire.identifier(snapshot.id, bytes: 16) else {
            throw AndesiteSyncError.invalidPacket
        }
        let metadata = try AndesiteSyncWire.encode(snapshot)
        let text = String(decoding: metadata, as: UTF8.self)
        return try db.transaction {
            let prior = try db.queryValues("""
                SELECT metadata_json,content_hash,content_bytes
                FROM sync_inbox_snapshots
                WHERE origin_vault=? AND origin_epoch=? AND snapshot_id=?
                """, bindings: [.blob(source), .blob(epoch), .blob(id)])
            if !prior.isEmpty {
                guard prior == [[.text(text), .text(snapshot.contentSHA256), .blob(bytes)]] else {
                    throw AndesiteSyncError.sequenceConflict
                }
                return false
            }
            try db.executeValues("""
                INSERT INTO sync_inbox_snapshots(
                    origin_vault,origin_epoch,snapshot_id,
                    metadata_json,content_hash,content_bytes
                ) VALUES(?,?,?,?,?,?)
                """, bindings: [.blob(source), .blob(epoch), .blob(id),
                                 .text(text), .text(snapshot.contentSHA256), .blob(bytes)])
            return true
        }
    }

    /// Browse received history without applying any foreign operation.
    static func inboxChanges(db: SQLiteConnection, sourceVault: String,
                             sourceEpoch: String, after: Int64, limit: Int) throws
        -> AndesiteSyncChangeBatch {
        guard let source = AndesiteSyncWire.identifier(sourceVault, bytes: 16),
              let epoch = AndesiteSyncWire.identifier(sourceEpoch, bytes: 16),
              after >= 0, (1...AndesiteSyncWire.maximumChangesPerBatch).contains(limit)
        else { throw AndesiteSyncError.invalidPacket }
        let cursors = try db.queryValues("""
            SELECT last_seq FROM sync_inbox_cursors
            WHERE origin_vault=? AND origin_epoch=?
            """, bindings: [.blob(source), .blob(epoch)])
        guard cursors.count == 1,
              case .integer(let head) = cursors[0][0], after <= head else {
            throw AndesiteSyncError.historyGap
        }
        let rows = try db.queryValues("""
            SELECT seq,event_json,content_hash,content_bytes
            FROM sync_inbox_changes
            WHERE origin_vault=? AND origin_epoch=? AND seq>?
            ORDER BY seq LIMIT ?
            """, bindings: [.blob(source), .blob(epoch), .integer(after),
                             .integer(Int64(limit))])
        var values: [AndesiteSyncChange] = []
        for row in rows {
            guard row.count == 4,
                  case .integer(let sequence) = row[0],
                  sequence == after + Int64(values.count) + 1,
                  case .text(let event) = row[1] else {
                throw AndesiteSyncError.sequenceConflict
            }
            let digest: String?
            let content: String?
            switch (row[2], row[3]) {
            case (.null, .null): digest = nil; content = nil
            case (.text(let hash), .blob(let bytes)):
                digest = hash; content = bytes.base64EncodedString()
            default: throw AndesiteSyncError.contentMismatch
            }
            let candidate = AndesiteSyncChange(sequence: sequence, eventJSON: event,
                                               contentSHA256: digest,
                                               contentBase64: content)
            _ = try AndesiteSyncWire.validateEvent(candidate)
            let probe = AndesiteSyncChangeBatch(
                protocolVersion: 1, sourceVault: sourceVault,
                sourceEpoch: sourceEpoch, after: after,
                changes: values + [candidate], headSequence: head)
            do { _ = try AndesiteSyncWire.encode(probe) }
            catch AndesiteSyncError.artifactTooLarge {
                if values.isEmpty { throw AndesiteSyncError.artifactTooLarge }
                break
            }
            values.append(candidate)
        }
        return AndesiteSyncChangeBatch(
            protocolVersion: 1, sourceVault: sourceVault,
            sourceEpoch: sourceEpoch, after: after,
            changes: values, headSequence: head)
    }

    static func inboxSnapshot(db: SQLiteConnection, sourceVault: String,
                              sourceEpoch: String, snapshotID: String) throws
        -> AndesiteSyncSnapshot {
        guard let source = AndesiteSyncWire.identifier(sourceVault, bytes: 16),
              let epoch = AndesiteSyncWire.identifier(sourceEpoch, bytes: 16),
              let id = AndesiteSyncWire.identifier(snapshotID, bytes: 16) else {
            throw AndesiteSyncError.invalidPacket
        }
        let rows = try db.queryValues("""
            SELECT metadata_json,content_hash,content_bytes
            FROM sync_inbox_snapshots
            WHERE origin_vault=? AND origin_epoch=? AND snapshot_id=?
            """, bindings: [.blob(source), .blob(epoch), .blob(id)])
        guard rows.count == 1,
              case .text(let json) = rows[0][0],
              case .text(let digest) = rows[0][1],
              case .blob(let bytes) = rows[0][2] else {
            throw SnapshotError.notFound
        }
        let snapshot = try AndesiteSyncWire.decode(
            AndesiteSyncSnapshot.self, bytes: Data(json.utf8))
        guard snapshot.sourceVault == sourceVault,
              snapshot.sourceEpoch == sourceEpoch,
              snapshot.id == snapshotID,
              snapshot.contentSHA256 == digest,
              try AndesiteSyncWire.validateSnapshot(snapshot) == bytes else {
            throw AndesiteSyncError.contentMismatch
        }
        return snapshot
    }

    static func inboxSnapshotList(db: SQLiteConnection, sourceVault: String,
                                  sourceEpoch: String, limit: Int, offset: Int) throws
        -> [String: Any] {
        guard let source = AndesiteSyncWire.identifier(sourceVault, bytes: 16),
              let epoch = AndesiteSyncWire.identifier(sourceEpoch, bytes: 16),
              (1...100).contains(limit), (0...100_000).contains(offset) else {
            throw AndesiteSyncError.invalidPacket
        }
        let count = try db.queryValues("""
            SELECT count(*) FROM sync_inbox_snapshots
            WHERE origin_vault=? AND origin_epoch=?
            """, bindings: [.blob(source), .blob(epoch)])
        guard case .integer(let total) = count.first?.first else {
            throw AndesiteSyncError.invalidPacket
        }
        let rows = try db.queryValues("""
            SELECT lower(hex(snapshot_id)),content_hash,length(content_bytes)
            FROM sync_inbox_snapshots
            WHERE origin_vault=? AND origin_epoch=?
            ORDER BY snapshot_id LIMIT ? OFFSET ?
            """, bindings: [.blob(source), .blob(epoch),
                             .integer(Int64(limit)), .integer(Int64(offset))])
        let items: [[String: Any]] = try rows.map { row in
            guard row.count == 3, case .text(let id) = row[0],
                  case .text(let digest) = row[1],
                  case .integer(let length) = row[2] else {
                throw AndesiteSyncError.invalidPacket
            }
            return ["snapshot": id, "sha256": digest, "bytes": length]
        }
        return ["snapshots": items, "total": total, "offset": offset,
                "nextOffset": Int64(offset + items.count) < total ?
                    (offset + items.count) as Any : NSNull()]
    }

    static func inbox(db: SQLiteConnection, limit: Int, offset: Int) throws
        -> [String: Any] {
        guard (1...100).contains(limit), (0...100_000).contains(offset) else {
            throw AndesiteSyncError.invalidPacket
        }
        let counts = try db.queryValues("SELECT count(*) FROM sync_inbox_cursors")
        guard case .integer(let total) = counts.first?.first else {
            throw AndesiteSyncError.invalidPacket
        }
        let rows = try db.queryValues("""
            SELECT c.origin_vault,c.origin_epoch,c.last_seq,
                  (SELECT count(*) FROM sync_inbox_snapshots s
                    WHERE s.origin_vault=c.origin_vault
                      AND s.origin_epoch=c.origin_epoch)
            FROM sync_inbox_cursors c
            ORDER BY c.origin_vault,c.origin_epoch LIMIT ? OFFSET ?
            """, bindings: [.integer(Int64(limit)), .integer(Int64(offset))])
        let items: [[String: Any]] = try rows.map { row in
            guard row.count == 4, case .blob(let source) = row[0],
                  case .blob(let epoch) = row[1],
                  case .integer(let last) = row[2],
                  case .integer(let snaps) = row[3] else {
                throw AndesiteSyncError.invalidPacket
            }
            return ["sourceVault": AndesiteSyncWire.hex(source),
                    "sourceEpoch": AndesiteSyncWire.hex(epoch),
                    "acknowledgedSequence": last, "snapshots": snaps]
        }
        return ["sources": items, "total": total, "offset": offset,
                "nextOffset": Int64(offset + items.count) < total ?
                    (offset + items.count) as Any : NSNull(),
                "appliedToVault": false]
    }

    static func pendingSnapshots(db: SQLiteConnection, vaultID: Data,
                                 peer: String, limit: Int) throws -> [Data] {
        guard validPeer(peer), (1...100).contains(limit) else {
            throw AndesiteSyncError.invalidPeer
        }
        let rows = try db.queryValues("""
            SELECT s.id
            FROM recovery_snapshots s
            LEFT JOIN sync_outgoing_snapshots a
              ON a.peer_key=? AND a.snapshot_id=s.id
            WHERE s.vault_id=? AND a.snapshot_id IS NULL
            ORDER BY s.created_at,s.id LIMIT ?
            """, bindings: [.text(peer), .blob(vaultID), .integer(Int64(limit))])
        return try rows.map { row in
            guard row.count == 1, case .blob(let id) = row[0],
                  id.count == 16 else { throw AndesiteSyncError.invalidPacket }
            return id
        }
    }

    static func acknowledgeSnapshot(db: SQLiteConnection, vaultID: Data,
                                    peer: String, snapshot: AndesiteSyncSnapshot)
        throws {
        guard validPeer(peer), snapshot.sourceVault == AndesiteSyncWire.hex(vaultID),
              snapshot.sourceEpoch == AndesiteSyncWire.hex(try epoch(db: db, vaultID: vaultID)),
              let id = AndesiteSyncWire.identifier(snapshot.id, bytes: 16) else {
            throw AndesiteSyncError.invalidPacket
        }
        let rows = try db.queryValues("""
            SELECT lower(hex(content_hash)),byte_length,entry_id,revision_id
            FROM recovery_snapshots WHERE vault_id=? AND id=?
            """, bindings: [.blob(vaultID), .blob(id)])
        guard rows.count == 1, case .text(let digest) = rows[0][0],
              case .integer(let length) = rows[0][1],
              case .blob(let document) = rows[0][2],
              case .blob(let revision) = rows[0][3],
              digest == snapshot.contentSHA256,
              length == snapshot.byteLength,
              AndesiteSyncWire.hex(document) == snapshot.document,
              AndesiteSyncWire.hex(revision) == snapshot.revision else {
            throw AndesiteSyncError.contentMismatch
        }
        try db.transaction {
            let existing = try db.queryValues("""
                SELECT content_hash FROM sync_outgoing_snapshots
                WHERE peer_key=? AND snapshot_id=?
                """, bindings: [.text(peer), .blob(id)])
            if !existing.isEmpty {
                guard existing == [[.text(digest)]] else {
                    throw AndesiteSyncError.sequenceConflict
                }
                return
            }
            try db.executeValues("""
                INSERT INTO sync_outgoing_snapshots(
                    peer_key,snapshot_id,content_hash,acknowledged_at
                ) VALUES(?,?,?,?)
                """, bindings: [.text(peer), .blob(id), .text(digest),
                                 .text(ISO8601DateFormatter().string(from: Date()))])
        }
    }

    static func acknowledged(db: SQLiteConnection, peer: String) throws -> Int64 {
        guard validPeer(peer) else { throw AndesiteSyncError.invalidPeer }
        let rows = try db.queryValues(
            "SELECT acknowledged_seq FROM sync_outgoing_peers WHERE peer_key=?",
            bindings: [.text(peer)])
        guard let first = rows.first else { return 0 }
        guard rows.count == 1, case .integer(let value) = first[0] else {
            throw AndesiteSyncError.invalidPacket
        }
        return value
    }

    static func recordAcknowledgement(db: SQLiteConnection, vaultID: Data,
                                      peer: String, batch: AndesiteSyncChangeBatch,
                                      receipt: AndesiteSyncReceipt) throws {
        guard validPeer(peer), batch.sourceVault == AndesiteSyncWire.hex(vaultID),
              receipt.sourceVault == batch.sourceVault,
              receipt.sourceEpoch == batch.sourceEpoch,
              receipt.acknowledgedSequence == batch.through,
              batch.through >= batch.after else { throw AndesiteSyncError.invalidPacket }
        let current = try acknowledged(db: db, peer: peer)
        guard current == batch.after || current == batch.through else {
            throw AndesiteSyncError.historyGap
        }
        try db.executeValues("""
            INSERT INTO sync_outgoing_peers(peer_key,acknowledged_seq,updated_at)
            VALUES(?,?,?)
            ON CONFLICT(peer_key) DO UPDATE SET
              acknowledged_seq=excluded.acknowledged_seq,
              updated_at=excluded.updated_at
            """, bindings: [.text(peer), .integer(batch.through),
                             .text(ISO8601DateFormatter().string(from: Date()))])
    }

    private static func validPeer(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 256 &&
        !key.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }
}
