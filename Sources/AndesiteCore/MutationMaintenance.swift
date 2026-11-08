import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Metadata only: inspection never prints document contents.
public struct MutationVersion: Codable, Sendable, Equatable {
    public let role: String
    public let path: String
    public let hash: String
    public let fingerprint: FileFingerprint?
    public let bytes: Int
}

public struct MutationInspection: Sendable {
    public let operation: MutationOperation
    public let parentRevision: Data
    public let expectedOriginal: FileFingerprint
    public let expectedStage: FileFingerprint?
    public let previousDecisions: Int
    public let audit: [String]
    public let versions: [MutationVersion]
    public let diagnostics: [String]
    public let choices: [String]
    public let strategy: String?
    public let outcome: String?
}

public struct MutationArtifact: Sendable {
    public let operationID: Data
    public let path: String
    public let status: String
    public let diagnostic: String
    public let logicalBytes: Int64
    /// Allocated blocks, not logical bytes. APFS sharing/compression can make
    /// actual volume-space recovery smaller; this is not an exclusive-block count.
    public let allocatedBytes: Int64
    public let eligible: Bool
}

extension MutationFilesystem {
    /// Bounded, descriptor-relative census; symlinks are never traversed. The
    /// returned spellings are hints, reopened and identity-checked by callers.
    func census() throws -> (files: [String], directories: [String]) {
        var files: [String] = [], directories = [String](), count = 0
        let device = identities.last!.device
        func visit(_ fd: Int32, _ prefix: String, _ depth: Int) throws {
            guard depth < 128 else { throw MutationError.conflict("relocation census depth limit") }
            let copy = dup(fd)
            guard copy >= 0 else { throw MutationError.conflict("relocation census descriptor failure") }
            guard let stream = fdopendir(copy) else { close(copy); throw MutationError.conflict("relocation census stream failure") }
            defer { closedir(stream) }
            directories.append(prefix)
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw MutationError.conflict("incomplete relocation census") }; break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                count += 1
                guard count <= 100_000 else { throw MutationError.conflict("relocation census exceeds 100000 entries") }
                var s = stat()
                guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw MutationError.conflict("namespace changed during census") }
                let relative = prefix + name
                if s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    guard UInt64(s.st_dev) == device, s.st_uid == geteuid(), s.st_mode & 0o022 == 0 else { throw MutationError.conflict("unsafe directory in relocation census") }
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw MutationError.conflict("directory changed during census") }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, DirectoryIdentity(opened) == DirectoryIdentity(s) else { throw MutationError.conflict("directory replaced during census") }
                    try visit(child, relative + "/", depth + 1)
                } else { files.append(relative) }
            }
        }
        try visit(directory, "", 0)
        try verifyChain()
        return (files, directories)
    }
}

extension MutationJournal {
    struct Located { let path: String; let fs: MutationFilesystem }
    struct Retirement { let path: String; let hint: FileFingerprint; let hash: String; let state: String }
    func bindings(_ r: Record) -> [SQLiteValue] { [.blob(vaultID), .blob(r.operation.id)] }
    func retirement(_ r: Record) throws -> Retirement? {
        guard let row = try db.queryValues("SELECT path,hint,hash,state FROM mutation_retirements WHERE vault_id=? AND operation_id=?", bindings: bindings(r)).first else { return nil }
        guard case .text(let path) = row[0], case .blob(let hint) = row[1], case .text(let hash) = row[2], case .text(let state) = row[3] else { throw VaultRuntimeError.inconsistentCatalog }
        return try Retirement(path: path, hint: JSONDecoder().decode(FileFingerprint.self, from: hint), hash: hash, state: state)
    }
    func decision(_ r: Record) throws -> [SQLiteValue]? {
        try db.queryValues("SELECT strategy,evidence,outcome,base_revision,outcome_revision FROM mutation_decisions WHERE vault_id=? AND operation_id=?", bindings: bindings(r)).first
    }
    func decisionFinished(_ r: Record) throws -> Bool {
        guard let d = try decision(r) else { return false }; return d[2] == .text("completed")
    }
    func ownedStage(_ r: Record) throws -> FileFingerprint? {
        if let stage = r.stage { return stage }
        let row = try db.queryValues("SELECT owned_hint FROM mutation_journal WHERE vault_id=? AND id=?", bindings: bindings(r))
        if case .blob(let hint) = row.first?.first { return try JSONDecoder().decode(FileFingerprint.self, from: hint) }
        return nil
    }
    func isOwned(_ observation: ObservedFile, _ r: Record) throws -> Bool {
        // Birth identity is mandatory for cross-path and retirement authority.
        guard observation.fingerprint.renameIdentity != nil else { return false }
        return try observation.fingerprint.sameInode(as: r.original) || ownedStage(r).map { observation.fingerprint.sameInode(as: $0) } == true
    }
    func census() throws -> (files: [String], directories: [String]) {
        try filesystem(path: ".andesite-census").census()
    }
    func artifactLocation(_ r: Record) throws -> Located {
        let suffix = r.operation.artifact
        let prefix = try VaultPath(r.operation.path).components.dropLast().joined(separator: "/")
        let direct = prefix.isEmpty ? suffix : prefix + "/" + suffix
        if let fs = try? filesystem(path: direct), fs.identities.last == r.directories.last {
            return Located(path: direct, fs: fs)
        }
        var matches: [Located] = []
        for directory in try census().directories {
            let path = directory + suffix
            let fs = try filesystem(path: path)
            if fs.identities.last == r.directories.last { matches.append(Located(path: path, fs: fs)) }
        }
        guard matches.count == 1 else { throw MutationError.conflict("original artifact parent cannot be uniquely located") }
        // A moved parent's device/inode alone is not enough. Corroborate with
        // the owned file's birth identity; an absent artifact is NOT evidence.
        let observation = try matches[0].fs.observe(suffix, maximumBytes: maximumBytes)
        guard try isOwned(observation, r) else { throw MutationError.conflict("relocated artifact ownership is uncertain") }
        return matches[0]
    }
    func currentLocation(_ r: Record) throws -> Located {
        var candidates: [Located] = []
        // A path is not document identity. Even the original spelling must have
        // an original or durably staged birth identity.
        for path in try census().files where !path.split(separator: "/").last!.hasPrefix(".andesite-") {
            let fs = try filesystem(path: path)
            if let observed = try? fs.observe(fs.name, maximumBytes: maximumBytes), try isOwned(observed, r) {
                candidates.append(Located(path: path, fs: fs))
            }
        }
        guard candidates.count == 1 else { throw MutationError.conflict("current document inode is missing, replaced, or ambiguous; export versions instead") }
        return candidates[0]
    }
    func version(_ role: String, _ located: Located) throws -> (MutationVersion, Data) {
        let observed = try located.fs.observe(located.fs.name, maximumBytes: maximumBytes)
        return (MutationVersion(role: role, path: located.path, hash: ObjectStore.hash(observed.bytes), fingerprint: observed.fingerprint, bytes: observed.bytes.count), observed.bytes)
    }
    func evidence(_ r: Record) throws -> [(MutationVersion, Data)] {
        var versions: [(MutationVersion, Data)] = []
        for (role, id) in [("intended", r.operation.snapshotID), ("preimage", r.operation.preimageID)] {
            let (s, bytes) = try snapshot(id)
            versions.append((MutationVersion(role: role, path: s.originalPath, hash: s.contentHash, fingerprint: nil, bytes: bytes.count), bytes))
        }
        versions.append(try version("current", currentLocation(r)))
        let artifact = try artifactLocation(r)
        if let _ = try artifact.fs.info(artifact.fs.name) {
            let v = try version("artifact", artifact)
            guard let fp = v.0.fingerprint, try isOwned(ObservedFile(fingerprint: fp, bytes: v.1), r) else { throw MutationError.conflict("artifact identity does not belong to this operation") }
            versions.append(v)
        } else {
            // Only a never-created intent may resolve without filesystem evidence.
            guard r.stage == nil, try ownedStage(r) == nil,
                  r.operation.state == "quarantined" || r.operation.state == "prepared" else { throw MutationError.conflict("expected artifact is missing; absence does not authorize resolution") }
        }
        return versions
    }
    func inspect(_ id: Data) throws -> MutationInspection {
        let r = try reload(id)
        var versions: [MutationVersion] = [], diagnostics = [r.operation.diagnostic], choices: [String] = []
        for (role, snapshotID) in [("intended", r.operation.snapshotID), ("preimage", r.operation.preimageID)] {
            do { let (s, bytes) = try snapshot(snapshotID); versions.append(MutationVersion(role: role, path: s.originalPath, hash: s.contentHash, fingerprint: nil, bytes: bytes.count)) }
            catch { diagnostics.append("\(role): immutable verification failed") }
        }
        for (role, locate) in [("current", currentLocation), ("artifact", artifactLocation)] {
            do { let l = try locate(r); let v = try version(role, l).0; versions.append(v)
                if let fp = v.fingerprint, try !isOwned(ObservedFile(fingerprint: fp, bytes: Data()), r) { diagnostics.append("\(role): UNVERIFIED ownership; no resolution or retirement authority") }
            } catch { diagnostics.append("\(role): \(error)") }
        }
        if let e = try? evidence(r), let candidate = e.first(where: { $0.0.role == "current" }),
           candidate.0.path.lowercased().hasSuffix(".md"), String(data: candidate.1, encoding: .utf8) != nil {
            choices = ["accept-current", "preserve-current"]
            let current = e.first { $0.0.role == "current" }!
            if current.0.fingerprint?.sameInode(as: r.original) == true, current.1 == (try snapshot(r.operation.preimageID).1),
               try db.queryValues("SELECT head_revision FROM entries WHERE vault_id=? AND id=?", bindings: [.blob(vaultID), .blob(r.operation.entryID)]) == [[.blob(r.parent)]] { choices.append("cancel-unpublished") }
            if current.0.fingerprint?.sameInode(as: r.stage ?? r.original) == true, r.stage != nil,
               current.1 == (try snapshot(r.operation.snapshotID).1) { choices.append("complete-published") }
        }
        if let fs = try? filesystem(path: r.operation.path), let observed = try? fs.observe(fs.name, maximumBytes: maximumBytes),
           try !isOwned(observed, r) {
            versions.append(MutationVersion(role: "path-occupant", path: r.operation.path, hash: ObjectStore.hash(observed.bytes), fingerprint: observed.fingerprint, bytes: observed.bytes.count))
            diagnostics.append("Original path is occupied by an unrelated inode; it will never be overwritten or adopted by resolution")
        }
        for row in try db.queryValues("SELECT role,hash,byte_length,path,hint FROM mutation_versions WHERE vault_id=? AND operation_id=? ORDER BY role,hash", bindings: bindings(r)) {
            guard case .text(let role) = row[0], case .blob(let hash) = row[1], case .integer(let length) = row[2], case .text(let path) = row[3] else { throw VaultRuntimeError.inconsistentCatalog }
            let fp: FileFingerprint?
            if case .blob(let hint) = row[4] { fp = try JSONDecoder().decode(FileFingerprint.self, from: hint) } else { fp = nil }
            _ = try objects.get(Self.hex(hash), maximumBytes: maximumBytes)
            versions.append(MutationVersion(role: "preserved:" + role, path: path, hash: Self.hex(hash), fingerprint: fp, bytes: Int(length)))
        }
        if let current = versions.first(where: { $0.role == "current" }), current.hash != versions.first(where: { $0.role == "intended" })?.hash {
            diagnostics.append("Current content differs from intended restoration; accepting it creates/preserves external revision lineage")
        }
        let d = try decision(r)
        let strategy: String?; if case .text(let s) = d?[0] { strategy = s } else { strategy = nil }
        let outcome: String?; if case .text(let s) = d?[2] { outcome = s } else { outcome = nil }
        let archived = try db.queryValues("SELECT strategy,outcome,lower(hex(base_revision)),lower(hex(outcome_revision)),created_at FROM mutation_decision_history WHERE vault_id=? AND operation_id=? ORDER BY id", bindings: bindings(r))
        let active = try db.queryValues("SELECT strategy,outcome,lower(hex(base_revision)),lower(hex(outcome_revision)),created_at FROM mutation_decisions WHERE vault_id=? AND operation_id=?", bindings: bindings(r))
        let audit = (archived + active).map { "strategy=\($0[0]) outcome=\($0[1]) baseRevision=\($0[2]) resultRevision=\($0[3]) createdAt=\($0[4])" }
        return MutationInspection(operation: r.operation, parentRevision: r.parent, expectedOriginal: r.original, expectedStage: r.stage, previousDecisions: try db.queryValues("SELECT id FROM mutation_decision_history WHERE vault_id=? AND operation_id=?", bindings: bindings(r)).count, audit: audit, versions: versions, diagnostics: diagnostics.filter { !$0.isEmpty }, choices: choices, strategy: strategy, outcome: outcome)
    }
    func preserve(_ versions: [(MutationVersion, Data)], record r: Record) throws {
        for (v, bytes) in versions {
            guard try objects.put(bytes) == v.hash else { throw SnapshotError.inconsistentMetadata }
            let p = try ExternalCapture.prepare(path: VaultPath(v.path), observation: ObservedFile(fingerprint: v.fingerprint ?? r.original, bytes: bytes), objects: objects)
            try db.transaction {
                try ExternalCapture.registerObject(db: db, prepared: p, timestamp: ISO8601DateFormatter().string(from: Date()))
                try db.executeValues("INSERT OR IGNORE INTO mutation_versions(vault_id,operation_id,role,hash,byte_length,path,hint) VALUES(?,?,?,?,?,?,?)", bindings: bindings(r) + [.text(v.role), .blob(p.hashBytes), .integer(Int64(v.bytes)), .text(v.path), try v.fingerprint.map { .blob(try JSONEncoder().encode($0)) } ?? .null])

            }
        }
    }
    /// No filesystem write. The durable decision pins all observations. A retry
    /// after a crash must see the same evidence or remain quarantined.
    func resolve(_ id: Data, strategy: String) throws -> MutationOperation {
        let r = try reload(id)
        if let d = try decision(r) {
            if d[2] == .text("completed"), ["completed", "cancelled"].contains(r.operation.state) {
                guard d[0] == .text(strategy) else { throw MutationError.conflict("a different resolution is already recorded") }
                return r.operation
            }
            if d[2] == .text("pending"), d[0] != .text(strategy) { throw MutationError.conflict("a different pending resolution is already recorded") }
        }
        guard r.operation.state == "quarantined", try inspect(id).choices.contains(strategy) else { throw MutationError.conflict("strategy is not safe for the current verified evidence") }
        let base = try db.queryValues("SELECT head_revision FROM entries WHERE vault_id=? AND id=? AND state='live'", bindings: [.blob(vaultID), .blob(r.operation.entryID)])
        let prior = try decision(r)
        let priorBase = prior.map { [$0[2] == .text("completed") ? $0[4] : $0[3]] }
        guard base == [[.blob(r.parent)]] || base == [[.blob(r.operation.revisionID)]] ||
              priorBase.map({ base == [$0] }) == true else { throw MutationError.conflict("catalog lineage has diverged") }
        let e = try evidence(r), encoded = try JSONEncoder().encode(e.map(\.0))
        try preserve(e, record: r)
        try db.transaction {
            if let d = try decision(r), d[2] == .text("completed") {
                try db.executeValues("INSERT INTO mutation_decision_history(vault_id,operation_id,strategy,evidence,outcome,created_at,base_revision,outcome_revision) SELECT vault_id,operation_id,strategy,evidence,outcome,created_at,base_revision,outcome_revision FROM mutation_decisions WHERE vault_id=? AND operation_id=?", bindings: bindings(r))
                try db.executeValues("DELETE FROM mutation_decisions WHERE vault_id=? AND operation_id=?", bindings: bindings(r))
            }
            if let d = try decision(r) {
                let previous = try JSONDecoder().decode([MutationVersion].self, from: { if case .blob(let b) = d[1] { return b }; return Data() }())
                guard previous == e.map(\.0) else { throw MutationError.conflict("evidence changed since the durable resolution intent; quarantine retained") }
            } else {
                try db.executeValues("INSERT INTO mutation_decisions VALUES(?,?,?,?,?,?,?,NULL)", bindings: bindings(r) + [.text(strategy), .blob(encoded), .text("pending"), .real(Date().timeIntervalSince1970), base[0][0]])
            }
        }
        try fault("resolution-intent")
        try db.transaction {
            guard try evidence(r).map(\.0) == e.map(\.0) else { throw MutationError.conflict("external edit during resolution") }
            let current = e.first { $0.0.role == "current" }!
            let location = try currentLocation(r)
            let observation = try location.fs.observe(location.fs.name, maximumBytes: maximumBytes)
            let p = try ExternalCapture.prepare(path: VaultPath(location.path), observation: observation, objects: objects)
            guard p.valid else { throw MutationError.conflict("current bytes are not valid Markdown; export before manual repair") }
            let heads = try db.queryValues("SELECT head_revision FROM entries WHERE vault_id=? AND id=? AND state='live'", bindings: [.blob(vaultID), .blob(r.operation.entryID)])
            guard let active = try decision(r), heads == [[active[3]]] else { throw MutationError.conflict("catalog lineage has diverged since resolution intent") }
            var resultRevision: Data?
            // Explicit namespace collision check, including case/Unicode aliases.
            guard try db.queryValues("SELECT id FROM entries WHERE vault_id=? AND path_key=? AND state='live' AND id<>?", bindings: [.blob(vaultID), .text(p.path.portabilityKey), .blob(r.operation.entryID)]).isEmpty else { throw MutationError.conflict("relocated path belongs to another catalog document") }
            if strategy == "cancel-unpublished" {
                guard heads == [[.blob(r.parent)]], location.path == r.operation.path else { throw MutationError.conflict("cancellation requires the unchanged original catalog path") }
            }
            do {
                let restoring: Data? = strategy == "complete-published" && heads == [[.blob(r.parent)]] ? r.operation.revisionID : nil
                guard let captured = try ExternalCapture.publish(db: db, vaultID: vaultID, prepared: p, entryID: r.operation.entryID, at: Date(), restoringRevision: restoring) else { throw SnapshotError.inconsistentMetadata }
                resultRevision = captured.revisionID
                try SearchIndex.index(db: db, vaultID: vaultID, entryID: captured.entryID, revisionID: captured.revisionID, bytes: current.1, withinTransaction: true)
                _ = try preserveHead(entryID: captured.entryID, at: Date())
            }
            try fault("resolution-written")
            guard try evidence(r).map(\.0) == e.map(\.0) else { throw MutationError.conflict("external edit before resolution commit") }
            try setState(r, strategy == "cancel-unpublished" ? "cancelled" : "completed", "Explicit resolution: " + strategy + "; competing versions retained in mutation_decisions")
            try db.executeValues("UPDATE mutation_decisions SET outcome='completed',outcome_revision=? WHERE vault_id=? AND operation_id=?", bindings: [resultRevision.map(SQLiteValue.blob) ?? .null] + bindings(r))
        }
        try fault("resolution-completed")
        return try reload(id).operation
    }
    func exportVersion(_ id: Data, role: String, to destination: String) throws {
        let r = try reload(id)
        var bytes: Data?
        if role.hasPrefix("sha256:") {
            let hash = String(role.dropFirst(7))
            let preserved = try db.queryValues("SELECT lower(hex(hash)) FROM mutation_versions WHERE vault_id=? AND operation_id=?", bindings: bindings(r))
            guard preserved.contains([.text(hash)]) else { throw MutationError.conflict("hash is not preserved by this operation") }
            bytes = try objects.get(hash, maximumBytes: maximumBytes)
        }
        // Prefer durable decision evidence: this still works after retirement.
        if bytes == nil, let d = try decision(r), case .blob(let encoded) = d[1],
           let v = try JSONDecoder().decode([MutationVersion].self, from: encoded).first(where: { $0.role == role }) {
            bytes = try objects.get(v.hash, maximumBytes: maximumBytes)
        } else if role == "intended" || role == "preimage" {
            bytes = try snapshot(role == "intended" ? r.operation.snapshotID : r.operation.preimageID).1
        } else if role == "current" { bytes = try version(role, currentLocation(r)).1 }
        else if role == "artifact" { bytes = try version(role, artifactLocation(r)).1 }
        else if role == "path-occupant" { bytes = try filesystem(path: r.operation.path).observe(VaultPath(r.operation.path).components.last!, maximumBytes: maximumBytes).bytes }
        if role == "retirement", let t = try retirement(r) { bytes = try objects.get(t.hash, maximumBytes: maximumBytes) }
        guard let bytes else { throw MutationError.conflict("version is unavailable") }
        try SnapshotExport.publish(bytes, to: destination, excluding: [root, stateRoot])
    }
    func artifacts() throws -> [MutationArtifact] {
        try records().map { r in
            if let t = try retirement(r), t.state == "retired" {
                return MutationArtifact(operationID: r.operation.id, path: t.path, status: "retired", diagnostic: "durable retirement receipt; path is no longer excluded or owned", logicalBytes: 0, allocatedBytes: 0, eligible: false)
            }
            do {
                let l = try artifactLocation(r)
                if r.operation.state == "cancelled", r.stage == nil, try ownedStage(r) == nil, try l.fs.info(l.fs.name) == nil {
                    return MutationArtifact(operationID: r.operation.id, path: l.path, status: "not-observed", diagnostic: "cancelled without durable stage identity; absence gives no retirement authority", logicalBytes: 0, allocatedBytes: 0, eligible: false)
                }
                if let t = try retirement(r), t.state == "pending", try l.fs.info(l.fs.name) == nil {
                    return MutationArtifact(operationID: r.operation.id, path: l.path, status: "retirement-pending", diagnostic: "bytes preserved; repeat explicit cleanup to sync parent and commit receipt", logicalBytes: 0, allocatedBytes: 0, eligible: false)
                }
                let observation = try l.fs.observe(l.fs.name, maximumBytes: maximumBytes)
                guard try isOwned(observation, r), let s = try l.fs.info(l.fs.name) else { throw MutationError.conflict("artifact identity mismatch") }
                if let t = try retirement(r), observation.fingerprint != t.hint || ObjectStore.hash(observation.bytes) != t.hash {
                    return MutationArtifact(operationID: r.operation.id, path: l.path, status: "uncertain", diagnostic: "artifact changed after durable retirement intent; repeat cleanup will refuse deletion", logicalBytes: s.st_size, allocatedBytes: Int64(s.st_blocks) * 512, eligible: false)
                }
                let expected: String?
                if let d = try decision(r), case .blob(let data) = d[1] {
                    expected = try JSONDecoder().decode([MutationVersion].self, from: data).first { $0.role == "artifact" }?.hash
                } else if r.operation.state == "completed" { expected = try snapshot(r.operation.preimageID).0.contentHash }
                else if r.operation.state == "cancelled", r.stage != nil { expected = try snapshot(r.operation.snapshotID).0.contentHash }
                else { expected = nil }
                let referenced = try records().contains { other in
                    guard other.operation.id != r.operation.id, !["completed", "cancelled"].contains(other.operation.state) else { return false }
                    return try isOwned(observation, other)
                }
                let eligible = !referenced && ["completed", "cancelled"].contains(r.operation.state) && expected == ObjectStore.hash(observation.bytes)
                return MutationArtifact(operationID: r.operation.id, path: l.path, status: eligible ? "retirement-eligible" : r.operation.state, diagnostic: eligible ? "verified owned inode and preserved content; retirement preserves exact bytes first" : "retained: unresolved operation or content differs from verified completion", logicalBytes: s.st_size, allocatedBytes: Int64(s.st_blocks) * 512, eligible: eligible)
            } catch {
                return MutationArtifact(operationID: r.operation.id, path: (try VaultPath(r.operation.path)).components.dropLast().map { $0 + "/" }.joined() + r.operation.artifact, status: "uncertain", diagnostic: "\(error)", logicalBytes: 0, allocatedBytes: 0, eligible: false)
            }
        }
    }
    /// Explicit operator maintenance only. Pending intent plus hash and identity
    /// distinguish an interrupted unlink from an unexplained disappearance.
    func cleanup(dryRun: Bool) throws -> [MutationArtifact] {
        let report = try artifacts()
        if dryRun { return report }
        for r in try records() {
            guard ["completed", "cancelled"].contains(r.operation.state) else { continue }
            if let t = try retirement(r), t.state == "retired" { continue }
            var t = try retirement(r)
            if t == nil {
                guard report.contains(where: { $0.operationID == r.operation.id && $0.eligible }) else { continue }
                let l = try artifactLocation(r), v = try version("artifact", l)
                guard let fp = v.0.fingerprint, try isOwned(ObservedFile(fingerprint: fp, bytes: v.1), r) else { throw MutationError.conflict("retirement ownership changed") }
                let preserved = MutationVersion(role: "retirement", path: v.0.path, hash: v.0.hash, fingerprint: v.0.fingerprint, bytes: v.0.bytes)
                try preserve([(preserved, v.1)], record: r)
                try db.executeValues("INSERT INTO mutation_retirements VALUES(?,?,?,?,?,'pending')", bindings: bindings(r) + [.text(l.path), .blob(try JSONEncoder().encode(fp)), .text(v.0.hash)])
                t = try retirement(r)
                try fault("retirement-intent")
            }
            guard let t else { throw VaultRuntimeError.inconsistentCatalog }
            let located = try artifactLocation(r)
            let fs = located.fs
            if Array(located.path.utf8) != Array(t.path.utf8) {
                let moved = try fs.observe(fs.name, maximumBytes: maximumBytes)
                guard moved.fingerprint == t.hint, ObjectStore.hash(moved.bytes) == t.hash else { throw MutationError.conflict("relocated retirement evidence changed") }
                try db.executeValues("UPDATE mutation_retirements SET path=? WHERE vault_id=? AND operation_id=?", bindings: [.text(located.path)] + bindings(r))
            }
            guard fs.identities.last == r.directories.last else { throw MutationError.conflict("retirement parent identity changed") }
            // Verify preserved bytes even on the missing-file restart branch.
            _ = try objects.get(t.hash, maximumBytes: maximumBytes)
            try fault("retirement-before-unlink")
            if try fs.info(fs.name) != nil {
                let now = try fs.observe(fs.name, maximumBytes: maximumBytes)
                guard now.fingerprint == t.hint, ObjectStore.hash(now.bytes) == t.hash,
                      try isOwned(now, r) else { throw MutationError.conflict("retirement evidence changed; no deletion") }
                try fs.verifyChain()
                guard unlinkat(fs.directory, fs.name, 0) == 0 else { throw MutationError.conflict("retirement unlink failed") }
            }
            try fault("retirement-unlinked")
            try fs.syncDirectory()
            try fs.verifyChain()
            try db.executeValues("UPDATE mutation_retirements SET state='retired' WHERE vault_id=? AND operation_id=?", bindings: bindings(r))
            try fault("retirement-completed")
        }
        return try artifacts()
    }
}
