import Foundation
import Testing
@testable import AndesiteCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Pulls `from`'s feed into `to` in small pages and resolves it, exactly as
/// the HTTP client and server do, without the transport.
@discardableResult
func pull(_ to: VaultRuntime, from: VaultRuntime, page: Int = 3) throws -> SyncReport {
    let peer = try from.syncIdentity()
    var cursor = try to.syncCursor(peer)
    while true {
        let batch = try from.syncFeed(after: cursor, limit: page)
        for record in batch.records { if let hash = record.hash { try transfer(hash, size: record.size!, from: from, to: to) } }
        try to.receive(batch)
        cursor = batch.through
        if cursor >= batch.head { break }
    }
    return try to.resolvePending()
}

/// Copies an object in small chunks, resuming any partial transfer.
func transfer(_ hash: String, size: Int64, from: VaultRuntime, to: VaultRuntime, chunk: Int = 5) throws {
    guard let missing = try to.missingObjects([hash]).first else { return }
    var offset = missing.received
    repeat {
        let data = try from.objectChunk(hash, offset: offset, length: Int(min(Int64(chunk), size - offset)))
        offset = try to.receiveChunk(hash, size: size, offset: offset, data)
    } while offset < size
}

func sync(_ a: VaultRuntime, _ b: VaultRuntime) throws {
    _ = try a.reconcile(); _ = try b.reconcile()
    let first = try pull(a, from: b), second = try pull(b, from: a)
    #expect(first.pending == 0 && second.pending == 0, "\(first.failures) \(second.failures)")
}

/// Live documents (id, path, head) plus the bytes on disk.
func snapshot(_ v: VaultRuntime, _ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for row in try v.requireOpen().db.queryValues(
        "SELECT lower(hex(id)),path,lower(hex(head_revision)) FROM entries WHERE vault_id=? AND state='live'",
        bindings: [.blob(v.vaultID)]) {
        guard case .text(let id) = row[0], case .text(let path) = row[1], case .text(let head) = row[2] else { continue }
        let bytes = (try? Data(contentsOf: root.appendingPathComponent(path))) ?? Data()
        result[path] = "\(id) \(head) \(ObjectStore.hash(bytes))"
    }
    return result
}

final class Pair {
    let fa: RuntimeFixture, fb: RuntimeFixture
    let a: VaultRuntime, b: VaultRuntime
    init() throws {
        fa = try RuntimeFixture(); fb = try RuntimeFixture()
        a = try VaultRuntime(configuration: fa.configuration)
        b = try VaultRuntime(configuration: fb.configuration)
        _ = try a.reconcile(); _ = try b.reconcile()
    }
    func text(_ side: RuntimeFixture, _ path: String) -> String? {
        try? String(contentsOf: side.vault.appendingPathComponent(path), encoding: .utf8)
    }
    func converged() throws -> Bool {
        try snapshot(a, fa.vault) == snapshot(b, fb.vault)
    }
    func close() { try? a.shutdown(); try? b.shutdown(); fa.clean(); fb.clean() }
}

@Test func syncPropagatesCreateEditMoveAndDeleteBothWays() throws {
    let p = try Pair(); defer { p.close() }
    let note = try p.a.create("Notes/한글 note.md", Data("# One\nfirst\n".utf8))
    try sync(p.a, p.b)
    #expect(p.text(p.fb, "Notes/한글 note.md") == "# One\nfirst\n")
    #expect(try p.b.document("Notes/한글 note.md").id == note.id)

    let edited = try p.b.update("Notes/한글 note.md", Data("# One\nsecond\n".utf8), revision: note.revisionID)
    try sync(p.a, p.b)
    #expect(p.text(p.fa, "Notes/한글 note.md") == "# One\nsecond\n")

    let moved = try p.a.move("Notes/한글 note.md", to: "Archive/renamed.md", revision: edited.revisionID)
    try sync(p.a, p.b)
    #expect(p.text(p.fb, "Notes/한글 note.md") == nil && p.text(p.fb, "Archive/renamed.md") == "# One\nsecond\n")

    try p.b.delete("Archive/renamed.md", revision: moved.revisionID)
    try sync(p.a, p.b)
    #expect(p.text(p.fa, "Archive/renamed.md") == nil)
    #expect(try p.a.history("Archive/renamed.md").count == 4)
    #expect(try p.converged())
    #expect(try p.a.search("second").isEmpty)
}

@Test func concurrentEditsMergeCleanlyOrKeepBothVersions() throws {
    let p = try Pair(); defer { p.close() }
    let base = try p.a.create("note.md", Data("title\none\ntwo\nthree\nfour\n".utf8))
    try sync(p.a, p.b)
    // Separate lines: one clean merge, identical on both sides.
    try p.a.update("note.md", Data("TITLE\none\ntwo\nthree\nfour\n".utf8), revision: base.revisionID)
    try p.b.update("note.md", Data("title\none\ntwo\nthree\nFOUR\n".utf8), revision: base.revisionID)
    try sync(p.a, p.b)
    #expect(p.text(p.fa, "note.md") == "TITLE\none\ntwo\nthree\nFOUR\n")
    #expect(try p.converged())
    #expect(try p.a.document("note.md").revisionID == p.b.document("note.md").revisionID)

    // The same line: one version stays, the other becomes a conflict copy.
    let head = try p.a.document("note.md").revisionID
    let fromA = try p.a.update("note.md", Data("TITLE\none from a\ntwo\nthree\nFOUR\n".utf8), revision: head)
    let fromB = try p.b.update("note.md", Data("TITLE\none from b\ntwo\nthree\nFOUR\n".utf8), revision: head)
    try sync(p.a, p.b)
    #expect(try p.converged())
    let (winner, loser) = fromA.revisionID.lexicographicallyPrecedes(fromB.revisionID) ? ("b", fromA) : ("a", fromB)
    #expect(p.text(p.fa, "note.md")?.contains("one from \(winner)") == true)
    let copy = "note (conflict \(loser.revisionID.hex.prefix(8))).md"
    #expect(p.text(p.fa, copy)?.contains("one from \(winner == "a" ? "b" : "a")") == true)
    #expect(p.text(p.fb, copy) == p.text(p.fa, copy))
}

@Test func editsSurviveConcurrentDeleteAndCombineWithRename() throws {
    let p = try Pair(); defer { p.close() }
    let one = try p.a.create("one.md", Data("one\n".utf8))
    let two = try p.a.create("two.md", Data("two\n".utf8))
    try sync(p.a, p.b)
    try p.a.delete("one.md", revision: one.revisionID)
    try p.b.update("one.md", Data("one edited\n".utf8), revision: one.revisionID)
    try p.a.move("two.md", to: "moved/two.md", revision: two.revisionID)
    try p.b.update("two.md", Data("two edited\n".utf8), revision: two.revisionID)
    try sync(p.a, p.b)
    #expect(p.text(p.fa, "one.md") == "one edited\n")
    #expect(p.text(p.fa, "moved/two.md") == "two edited\n" && p.text(p.fa, "two.md") == nil)
    #expect(try p.converged())

    // A delete against a mere rename wins.
    let moved = try p.a.document("moved/two.md")
    try p.a.delete("moved/two.md", revision: moved.revisionID)
    try p.b.move("moved/two.md", to: "elsewhere.md", revision: moved.revisionID)
    try sync(p.a, p.b)
    #expect(p.text(p.fb, "elsewhere.md") == nil && p.text(p.fb, "moved/two.md") == nil)
    #expect(try p.converged())
}

@Test func independentFilesAtOnePathAreNeverOverwritten() throws {
    let p = try Pair(); defer { p.close() }
    let a = try p.a.create("Same.md", Data("from a\n".utf8))
    let b = try p.b.create("same.md", Data("from b\n".utf8)) // a case variant
    let copyA = try p.a.create("copied.md", Data("identical\n".utf8))
    let copyB = try p.b.create("copied.md", Data("identical\n".utf8))
    try sync(p.a, p.b)
    #expect(try p.converged())
    let (keeper, aside) = a.id.lexicographicallyPrecedes(b.id) ? (a, b) : (b, a)
    let asidePath = (aside.id == a.id ? "Same" : "same") + " (conflict \(aside.id.hex.prefix(8))).md"
    #expect(try p.a.document(keeper.path).id == keeper.id)
    #expect(try p.a.document(asidePath).id == aside.id)
    #expect(Set([p.text(p.fa, keeper.path), p.text(p.fa, asidePath)]) == ["from a\n", "from b\n"])
    // Identical content: one document remains, no conflict copy.
    let kept = copyA.id.lexicographicallyPrecedes(copyB.id) ? copyA.id : copyB.id
    #expect(try p.a.document("copied.md").id == kept && p.b.document("copied.md").id == kept)
    #expect(try snapshot(p.a, p.fa.vault).count == 3)
}

@Test func duplicateReorderedAndInterruptedDeliveryIsSafe() throws {
    let p = try Pair(); defer { p.close() }
    let note = try p.a.create("note.md", Data("v1\n".utf8))
    try p.a.update("note.md", Data("v2\n".utf8), revision: note.revisionID)
    let all = try p.a.syncFeed(after: 0)
    let first = SyncBatch(vault: all.vault, epoch: all.epoch, records: [all.records[0]], through: all.records[0].sequence, head: all.head)
    let second = SyncBatch(vault: all.vault, epoch: all.epoch, records: [all.records[1]], through: all.head, head: all.head)
    for record in all.records { try transfer(record.hash!, size: record.size!, from: p.a, to: p.b) }

    // Out of order: the child before its parent is refused atomically.
    #expect(throws: SyncError.historyGap(all.records[1].revision)) { try p.b.receive(second) }
    #expect(try p.b.syncCursor(p.a.syncIdentity()) == 0)
    // Interrupted after one page: the document is pending, the cursor durable.
    #expect(try p.b.receive(first) == 1)
    #expect(try p.b.syncCursor(p.a.syncIdentity()) == first.through)
    #expect(try p.b.receive(first) == 0) // duplicate
    #expect(try p.b.receive(second) == 1)
    #expect(try p.b.receive(all) == 0)
    try p.b.resolvePending()
    #expect(p.text(p.fb, "note.md") == "v2\n")
    // Content that does not match its hash, or is absent, is rejected.
    #expect(throws: SyncError.self) { try p.b.receiveChunk(String(repeating: "a", count: 64), size: 6, offset: 0, Data("forged".utf8)) }
    var forged = all
    forged.records[0].revision = String(repeating: "c", count: 32)
    forged.records[0].hash = String(repeating: "b", count: 64)
    #expect(throws: SyncError.self) { try p.b.receive(forged) }
    forged.records[0].path = "../escape.md"
    #expect(throws: SyncError.self) { try p.b.receive(forged) }
    #expect(try p.converged())
}

@Test func unsyncedExternalEditIsMergedNotOverwritten() throws {
    let p = try Pair(); defer { p.close() }
    let base = try p.a.create("note.md", Data("a\nb\nc\nd\n".utf8))
    try sync(p.a, p.b)
    try p.a.update("note.md", Data("A\nb\nc\nd\n".utf8), revision: base.revisionID)
    // B's editor writes the file; no scan has seen it before the sync applies.
    try Data("a\nb\nc\nD\n".utf8).write(to: p.fb.vault.appendingPathComponent("note.md"))
    try pull(p.b, from: p.a)
    #expect(p.text(p.fb, "note.md") == "A\nb\nc\nD\n")
    try sync(p.a, p.b)
    #expect(try p.converged())
}

/// Random concurrent histories on two Vaults, synced repeatedly, must end
/// identical: same documents, paths, heads and bytes.
@Test(arguments: [20261109, 7] as [UInt64])
func randomConcurrentHistoriesConverge(seed: UInt64) throws {
    var rng = SeededGenerator(seed: seed)
    let p = try Pair(); defer { p.close() }
    let names = ["a.md", "b.md", "dir/c.md", "dir/D.md", "e.md"]
    func content() -> Data { Data((0..<5).map { "line \($0) \(Int.random(in: 0..<3, using: &rng))\n" }.joined().utf8) }
    func act(_ v: VaultRuntime, _ root: URL) {
        let live = (try? snapshot(v, root).keys.sorted()) ?? []
        let path = live.isEmpty ? names[0] : live[Int.random(in: 0..<live.count, using: &rng)]
        let head = try? v.document(path).revisionID
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: _ = try? v.create(names.randomElement(using: &rng)!, content())
        case 1, 2: if let head { _ = try? v.update(path, content(), revision: head) }
        case 3: if let head { _ = try? v.move(path, to: names.randomElement(using: &rng)!, revision: head) }
        case 4: if let head { try? v.delete(path, revision: head) }
        default: try? content().write(to: root.appendingPathComponent(path)) // an editor, seen at the next scan
        }
    }
    for round in 0..<25 {
        for _ in 0..<3 { act(p.a, p.fa.vault); act(p.b, p.fb.vault) }
        if round % 3 != 2 { try sync(p.a, p.b) }
    }
    try sync(p.a, p.b)
    try sync(p.a, p.b)
    let (left, right) = (try snapshot(p.a, p.fa.vault), try snapshot(p.b, p.fb.vault))
    #expect(left == right, "a=\(left) b=\(right)")
    #expect(try p.a.reconcile().revisionsCreated == 0)
    #expect(try p.a.status().unfinishedMutations == 0)
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Test func threeWayTextMergeIsByteExactAndSymmetric() {
    let base = Data("a\nb\nc\nd\ne".utf8)
    let left = Data("a\nB\nc\nd\ne".utf8), right = Data("a\nb\nc\nd\nE\nf".utf8)
    #expect(TextMerge.merge(base: base, left, right) == Data("a\nB\nc\nd\nE\nf".utf8))
    #expect(TextMerge.merge(base: base, right, left) == TextMerge.merge(base: base, left, right))
    #expect(TextMerge.merge(base: base, Data("a\nX\nc\nd\ne".utf8), Data("a\nY\nc\nd\ne".utf8)) == nil)
    // Precomposed and decomposed "é" are different lines.
    let nfc = Data("caf\u{E9}\n".utf8), nfd = Data("cafe\u{301}\n".utf8)
    #expect(TextMerge.merge(base: nfc, nfd, nfc) == nfd)
}
