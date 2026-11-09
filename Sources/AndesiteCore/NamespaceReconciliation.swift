import Foundation

struct CatalogFile {
    let id: Data
    let path: VaultPath
    let fingerprint: FileFingerprint?
    var name: String { path.components.joined(separator: "/") }
}

/// Identity is independent of bytes. Unique device/inode/birthtime evidence is
/// preferred even when paths are reused or exchanged. Atomic editor replacement
/// at an otherwise unchanged exact path retains the path's identity. Missing or
/// ambiguous cross-path evidence never merges histories.
struct NamespacePlan {
    let old: [CatalogFile]
    let assignment: [Int: Int] // scan index -> old index
    let moved: Set<Int>
    let deleted: Set<Int>
    private let oldKeys: Set<String>

    init(db: SQLiteConnection, vaultID: Data, scan: [ScannedFile]) throws {
        let old = try db.queryValues("SELECT id,path,fs_hint FROM entries WHERE vault_id=? AND state='live' ORDER BY id", bindings: [.blob(vaultID)]).map { row -> CatalogFile in
            guard case .blob(let id) = row[0], case .text(let name) = row[1] else { throw VaultRuntimeError.inconsistentCatalog }
            let fingerprint: FileFingerprint?
            if case .blob(let hint) = row[2] { fingerprint = try JSONDecoder().decode(FileFingerprint.self, from: hint) }
            else if row[2] == .null { fingerprint = nil }
            else { throw VaultRuntimeError.inconsistentCatalog }
            return try CatalogFile(id: id, path: VaultPath(name), fingerprint: fingerprint)
        }
        var priorIdentities: [String: [Int]] = [:], currentIdentities: [String: [Int]] = [:]
        for (index, file) in old.enumerated() {
            if let key = file.fingerprint?.renameIdentity { priorIdentities[key, default: []].append(index) }
        }
        for (index, file) in scan.enumerated() {
            if let key = file.fingerprint.renameIdentity { currentIdentities[key, default: []].append(index) }
        }
        var assignment: [Int: Int] = [:]
        var used = Set<Int>()
        for (identity, prior) in priorIdentities where prior.count == 1 {
            if let current = currentIdentities[identity], current.count == 1 {
                assignment[current[0]] = prior[0]; used.insert(prior[0])
            }
        }
        let byExactPath = Dictionary(uniqueKeysWithValues: old.enumerated().map { (Data($0.element.name.utf8), $0.offset) })
        for (index, file) in scan.enumerated() where assignment[index] == nil {
            if let prior = byExactPath[Data(file.path.components.joined(separator: "/").utf8)], !used.contains(prior) {
                assignment[index] = prior; used.insert(prior)
            }
        }
        self.old = old
        self.assignment = assignment
        self.moved = Set(assignment.compactMap { current, prior in
            Array(scan[current].path.components.joined(separator: "/").utf8) != Array(old[prior].name.utf8) ? prior : nil
        })
        self.deleted = Set(old.indices).subtracting(used)
        self.oldKeys = Set(old.map(\.path.portabilityKey))
    }

    func needsNamespaceCommit(index: Int, file: ScannedFile) -> Bool {
        if let prior = assignment[index] { return moved.contains(prior) }
        return oldKeys.contains(file.path.portabilityKey)
    }

    static func validateUnchanged(_ before: [ScannedFile], _ after: [ScannedFile]) throws {
        guard before.count == after.count else { throw VaultReadError.unstable }
        for (a, b) in zip(before, after) {
            guard Array(a.path.components.joined(separator: "/").utf8) == Array(b.path.components.joined(separator: "/").utf8), a.fingerprint == b.fingerprint else { throw VaultReadError.unstable }
        }
    }
}
