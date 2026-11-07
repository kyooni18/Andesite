import Foundation
import Testing
@testable import AndesiteCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private extension RuntimeFixture {
    func database() throws -> SQLiteConnection { try SQLiteConnection(path: state.appendingPathComponent("catalog.sqlite").path) }
    func remove(_ name: String) throws { try FileManager.default.removeItem(at: vault.appendingPathComponent(name)) }
    func move(_ from: String, _ to: String) throws {
        guard rename(vault.appendingPathComponent(from).path, vault.appendingPathComponent(to).path) == 0 else { throw VaultReadError.systemCall("test rename", errno) }
    }
}

@Test func snapshotSpacingCoalescingAndOrderlyShutdown() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let start = Date()
    func time(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    let runtime = try VaultRuntime(configuration: f.configuration)
    #expect(try runtime.snapshotPolicy() == SnapshotPolicy())
    try f.write("note.md", "# Initial\r\nexact bytes\r\n")
    #expect(try runtime.reconcile(at: time(0)).snapshotsCreated == 1)
    let first = try #require(runtime.snapshots().first)
    #expect(first.originalPath == "note.md" && first.reason == "interval")
    #expect(abs(first.expiresAt.timeIntervalSince(time(7 * 86400))) < 0.000001)
    #expect(try runtime.snapshotContents(first.id) == Data("# Initial\r\nexact bytes\r\n".utf8))
    #expect(try runtime.reconcile(at: time(1)).snapshotsCreated == 0)
    try f.write("note.md", "# Rapid one")
    #expect(try runtime.reconcile(at: time(2)).snapshotsCreated == 0)
    try f.write("note.md", "# Rapid two")
    #expect(try runtime.reconcile(at: time(3)).snapshotsCreated == 0)
    #expect(try runtime.status().revisions == 3)
    #expect(try runtime.snapshotStorage().pendingDocuments == 1)
    #expect(try runtime.reconcile(at: time(299)).snapshotsCreated == 0)
    // No new edit is needed to promote a pending, already durable revision.
    #expect(try runtime.reconcile(at: time(300)).snapshotsCreated == 1)
    let second = try #require(runtime.snapshots().last)
    #expect(try runtime.snapshotContents(second.id) == Data("# Rapid two".utf8))
    #expect(try !runtime.compareSnapshots(first.id, second.id).changes.isEmpty)
    try f.write("note.md", "# Transient")
    _ = try runtime.reconcile(at: time(301))
    try f.write("note.md", "# Rapid two")
    _ = try runtime.reconcile(at: time(302))
    #expect(try runtime.reconcile(at: time(600)).snapshotsCreated == 0)
    #expect(try runtime.snapshotStorage().pendingDocuments == 0)
    #expect(try runtime.snapshots().count == 2)
    try runtime.configureSnapshots(SnapshotPolicy(minimumInterval: 60, retentionSeconds: 100))
    #expect(try runtime.inspectSnapshot(first.id).expiresAt == first.expiresAt)
    try f.write("note.md", "# Across interval")
    #expect(try runtime.reconcile(at: time(601)).snapshotsCreated == 1)
    let across = try #require(runtime.snapshots().last)
    #expect(abs(across.expiresAt.timeIntervalSince(time(701))) < 0.000001)
    try f.write("note.md", "# Pending at exit")
    #expect(try runtime.reconcile(at: time(602)).snapshotsCreated == 0)
    try runtime.shutdown(at: time(603))
    let reopened = try VaultRuntime(configuration: f.configuration)
    #expect(try reopened.snapshotPolicy() == SnapshotPolicy(minimumInterval: 60, retentionSeconds: 100))
    let final = try #require(reopened.snapshots().last)
    #expect(final.reason == "shutdown")
    #expect(try reopened.snapshotContents(final.id) == Data("# Pending at exit".utf8))
    #expect(try reopened.reconcile(at: time(604)).snapshotsCreated == 0)
    #expect(try reopened.snapshotStorage().pendingDocuments == 0)
    try reopened.shutdown(at: time(605))
}

@Test func tombstonesPreservePendingSnapshotsAndFilenameRecreation() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let start = Date()
    try f.write("gone.md", "initial")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile(at: start)
    let initial = try #require(runtime.snapshots().first)
    try f.write("gone.md", "last captured before deletion")
    _ = try runtime.reconcile(at: start.addingTimeInterval(1))
    try f.remove("gone.md")
    // An incomplete scan is never confirmation of absence.
    try FileManager.default.createSymbolicLink(atPath: f.vault.appendingPathComponent("unsafe.md").path, withDestinationPath: "missing")
    #expect(throws: VaultReadError.unsafeFile) { try runtime.reconcile() }
    let db = try f.database()
    #expect(try db.scalarText("SELECT count(*) FROM entries WHERE state='live'") == "1")
    try f.remove("unsafe.md")
    // Snapshot registration and tombstone publication must roll back together.
    try db.execute("CREATE TRIGGER snapshot_fault BEFORE INSERT ON recovery_snapshots BEGIN SELECT RAISE(ABORT,'snapshot fault'); END")
    #expect(throws: SQLiteFailure.self) { try runtime.reconcile(at: start.addingTimeInterval(2)) }
    #expect(try db.scalarText("SELECT count(*) FROM revisions WHERE deleted=1") == "0")
    #expect(try db.scalarText("SELECT count(*) FROM changes") == "2")
    try db.execute("DROP TRIGGER snapshot_fault")
    let deletion = try runtime.reconcile(at: start.addingTimeInterval(3))
    #expect(deletion.deleted == 1 && deletion.snapshotsCreated == 1)
    let history = try runtime.snapshots(entryID: initial.entryID)
    #expect(history.count == 2 && history.allSatisfy { $0.documentState == "deleted" })
    let last = try #require(history.last)
    #expect(last.reason == "deletion")
    #expect(try runtime.snapshotContents(last.id) == Data("last captured before deletion".utf8))
    #expect(try runtime.reconcile().deleted == 0)
    #expect(try runtime.search("initial").isEmpty)
    try f.write("gone.md", "new identity")
    _ = try runtime.reconcile()
    let recreated = try runtime.snapshots(path: "gone.md")
    #expect(recreated.count == 3)
    #expect(Set(recreated.map(\.entryID)).count == 2)
    #expect(try db.scalarText("SELECT count(*) FROM revisions") == "4")
    #expect(try db.scalarText("SELECT next_seq FROM vaults") == "6")
    try runtime.shutdown()
    let reopened = try VaultRuntime(configuration: f.configuration)
    #expect(try reopened.snapshots(entryID: initial.entryID).count == 2)
    #expect(try reopened.reconcile().deleted == 0)
    try reopened.shutdown()
}

@Test func credibleMovesPreserveIdentityAcrossRestartAndPathReuse() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let start = Date()
    try f.write("노트.md", "first")
    var originalID = Data()
    do {
        let runtime = try VaultRuntime(configuration: f.configuration)
        _ = try runtime.reconcile(at: start)
        originalID = try #require(runtime.snapshots().first).entryID
        try f.write("노트.md", "pending before move")
        _ = try runtime.reconcile(at: start.addingTimeInterval(1))
        try runtime.shutdown(at: start.addingTimeInterval(2))
    }
    // Identity hints are persisted, not just held in memory. Rename and edit
    // before reconciliation; content hashes must not be the matching criterion.
    try FileManager.default.createDirectory(at: f.vault.appendingPathComponent("폴더"), withIntermediateDirectories: false)
    try f.move("노트.md", "폴더/Case.md")
    try f.write("폴더/Case.md", "changed while moving")
    let runtime = try VaultRuntime(configuration: f.configuration)
    let report = try runtime.reconcile(at: start.addingTimeInterval(3))
    #if canImport(Darwin)
    #expect(report.renamed == 1 && report.deleted == 0)
    let moved = try #require(runtime.snapshots(path: "폴더/Case.md").last)
    #expect(moved.entryID == originalID && moved.reason == "rename")
    #expect(try runtime.snapshotContents(moved.id) == Data("changed while moving".utf8))
    // Case-only moves and directory moves preserve identity and do not duplicate
    // identical snapshots. No case/Unicode normalization rewrites source names.
    let count = try runtime.snapshots().count
    try f.write("폴더/Case.md", "changed while moving\npending on rename")
    #expect(try runtime.reconcile(at: start.addingTimeInterval(4)).snapshotsCreated == 0)
    try f.move("폴더/Case.md", "폴더/cASE.md")
    let db = try f.database()
    try db.execute("CREATE TRIGGER move_fault BEFORE INSERT ON revisions BEGIN SELECT RAISE(ABORT,'move fault'); END")
    #expect(throws: SQLiteFailure.self) { try runtime.reconcile() }
    #expect(try db.scalarText("SELECT count(*) FROM entries WHERE state='reserved'") == "0")
    #expect(try runtime.snapshots().count == count)
    try db.execute("DROP TRIGGER move_fault")
    #expect(try runtime.reconcile().renamed == 1)
    try f.move("폴더", "이동한 폴더")
    #expect(try runtime.reconcile().renamed == 1)
    #expect(try runtime.snapshots().count == count + 1)
    #expect(try runtime.search("changed while moving").first?.entryID == originalID)
    // Reuse the old name while moving the existing inode elsewhere.
    try f.move("이동한 폴더/cASE.md", "elsewhere.md")
    try f.write("이동한 폴더/cASE.md", "unrelated recreated name")
    #expect(try runtime.reconcile().renamed == 1)
    #expect(try runtime.search("changed while moving").first?.entryID == originalID)
    #expect(try runtime.search("unrelated recreated name").first?.entryID != originalID)
    // Exchange two paths; namespace release/publication is one transaction.
    try f.move("elsewhere.md", "swap.tmp")
    try f.move("이동한 폴더/cASE.md", "elsewhere.md")
    try f.move("swap.tmp", "이동한 폴더/cASE.md")
    #expect(try runtime.reconcile().renamed == 2)
    #expect(try runtime.search("changed while moving").first?.entryID == originalID)
    // A moved invalid file retains incident bytes without releasing its old
    // identity/path or publishing disappearances. Correction completes the move.
    try Data([0xff]).write(to: f.vault.appendingPathComponent("이동한 폴더/cASE.md"))
    try f.move("이동한 폴더/cASE.md", "quarantined.md")
    let quarantined = try runtime.reconcile()
    #expect(quarantined.invalidMarkdown == 1 && quarantined.deleted == 0 && quarantined.renamed == 0)
    #expect(try runtime.search("changed while moving").isEmpty)
    try f.write("quarantined.md", "fixed after move")
    #expect(try runtime.reconcile().renamed == 1)
    #expect(try runtime.search("fixed after move").first?.entryID == originalID)
    #expect(try runtime.status().openIncidents == 0)
    #else
    // Linux stat currently lacks birthtime evidence in this implementation.
    #expect(report.deleted == 1 && report.renamed == 0)
    #expect(try runtime.snapshots(entryID: originalID).allSatisfy { $0.documentState == "deleted" })
    #endif
    try runtime.shutdown()
}

@Test func ambiguousAndHashIdenticalMovesNeverMergeHistories() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("a.md", "identical"); try f.write("b.md", "identical")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let old = Set(try runtime.snapshots().map(\.entryID))
    let db = try f.database()
    // Simulate indistinguishable/stale retained identity hints. Even a unique
    // matching content hash must not choose which document was moved.
    try db.execute("UPDATE entries SET fs_hint=(SELECT fs_hint FROM entries WHERE path='a.md')")
    try f.move("a.md", "c.md"); try f.move("b.md", "d.md")
    let report = try runtime.reconcile()
    #expect(report.deleted == 2 && report.renamed == 0)
    let all = try runtime.snapshots()
    let current = Set(all.filter { $0.documentState == "live" }.map(\.entryID))
    #expect(current.count == 2 && current.isDisjoint(with: old))
    #expect(all.filter { $0.documentState == "deleted" }.count == 2)
    let usage = try runtime.snapshotStorage()
    #expect(usage.objects.count == 1)
    #expect(usage.objects.first?.snapshots == 4 && usage.objects.first?.revisions == 4)
    #expect(usage.uniqueSnapshotBytes == Int64("identical".utf8.count))
    try runtime.shutdown()
}

@Test func snapshotRecoveryAfterInterruptedPublicationAndDatabaseLocking() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "first")
    let dbPath = f.state.appendingPathComponent("catalog.sqlite").path
    let start = Date()
    let db: SQLiteConnection
    do {
        let runtime = try VaultRuntime(configuration: f.configuration)
        _ = try runtime.reconcile(at: start)
        db = try f.database()
        try runtime.configureSnapshots(SnapshotPolicy(minimumInterval: 0))
        try db.execute("CREATE TRIGGER snapshot_fault BEFORE INSERT ON recovery_snapshots BEGIN SELECT RAISE(ABORT,'snapshot fault'); END")
        try f.write("note.md", "durable head, no snapshot yet")
        #expect(throws: SQLiteFailure.self) { try runtime.reconcile(at: start.addingTimeInterval(1)) }
        #expect(try runtime.status().revisions == 2)
        #expect(try db.scalarText("SELECT count(*) FROM recovery_snapshots") == "1")
        // Simulate an abrupt exit: release owner WITHOUT orderly shutdown/flush.
    }
    try db.execute("DROP TRIGGER snapshot_fault")
    // A newer disk edit must not erase recovery of the last captured head.
    try f.write("note.md", "new disk version after crash")
    let runtime = try VaultRuntime(configuration: f.configuration)
    let recovered = try #require(runtime.snapshots().last)
    #expect(recovered.reason == "recovery")
    #expect(try runtime.snapshotContents(recovered.id) == Data("durable head, no snapshot yet".utf8))
    #expect(throws: ProcessLockError.unavailable) { try VaultRuntime(configuration: f.configuration) }
    let locked = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let writer = Thread {
        defer { locked.signal(); finished.signal() }
        do {
            let other = try SQLiteConnection(path: dbPath)
            try other.execute("BEGIN IMMEDIATE")
            locked.signal()
            Thread.sleep(forTimeInterval: 0.15)
            try other.execute("ROLLBACK")
        } catch { Issue.record(error) }
    }
    writer.start()
    #expect(locked.wait(timeout: .now() + 10) == .success)
    // Runtime publication waits for SQLite's writer lock, never resets or drops
    // metadata to work around contention. WAL reads still see committed history.
    #expect(try runtime.snapshots().count == 2)
    #expect(try runtime.reconcile().revisionsCreated == 1)
    #expect(finished.wait(timeout: .now() + 10) == .success)
    #expect(try runtime.status().revisions == 3)
    #expect(try runtime.reconcile().revisionsCreated == 0)
    #expect(try db.scalarText("SELECT count(*) FROM changes") == "3")
    #expect(try db.scalarText("SELECT count(*) FROM recovery_snapshots") == "3")
    try runtime.shutdown()
    let restarted = try VaultRuntime(configuration: f.configuration)
    #expect(try restarted.snapshots().count == 3)
    #expect(try restarted.reconcile().revisionsCreated == 0)
    try restarted.shutdown()
}

@Test func snapshotExportIntegrityRetentionAndRestorationValidation() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let start = Date()
    let bytes = Data("# Café\r\noriginal\r\n".utf8)
    try bytes.write(to: f.vault.appendingPathComponent("a.md"))
    try bytes.write(to: f.vault.appendingPathComponent("b.md"))
    try Data([0xff]).write(to: f.vault.appendingPathComponent("invalid.md"))
    try Data([0xff]).write(to: f.vault.appendingPathComponent("invalid2.md"))
    let runtime = try VaultRuntime(configuration: f.configuration)
    try runtime.configureSnapshots(SnapshotPolicy(minimumInterval: 0, retentionSeconds: 10))
    _ = try runtime.reconcile(at: start)
    let first = try #require(runtime.snapshots(path: "a.md").first)
    #expect(throws: SnapshotError.invalidPolicy) { try runtime.configureSnapshots(SnapshotPolicy(minimumInterval: -1)) }
    let usage = try runtime.snapshotStorage(at: start.addingTimeInterval(11))
    #expect(usage.expirationEligible == 2 && usage.snapshots == 2)
    #expect(usage.logicalBytes == Int64(2 * bytes.count) && usage.uniqueSnapshotBytes == Int64(bytes.count))
    #expect(usage.objects.first { $0.contentHash == first.contentHash }?.revisions == 2)
    #expect(usage.objects.first { $0.byteLength == 1 }?.incidents == 2)
    // Expiration does not remove metadata, objects, revisions or incident pins.
    #expect(try runtime.snapshotContents(first.id) == bytes)
    let output = f.root.appendingPathComponent("recovered.md")
    try runtime.exportSnapshot(first.id, to: output.path)
    #expect(try Data(contentsOf: output) == bytes)
    #expect(throws: SnapshotError.unsafeExport) { try runtime.exportSnapshot(first.id, to: output.path) }
    #expect(throws: SnapshotError.unsafeExport) { try runtime.exportSnapshot(first.id, to: f.vault.appendingPathComponent("export.md").path) }
    #expect(throws: SnapshotError.unsafeExport) { try runtime.exportSnapshot(first.id, to: f.state.appendingPathComponent("export.md").path) }
    let alias = f.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.vault)
    #expect(throws: SnapshotError.unsafeExport) { try runtime.exportSnapshot(first.id, to: alias.appendingPathComponent("export.md").path) }
    let targetLink = f.root.appendingPathComponent("target.md")
    try FileManager.default.createSymbolicLink(at: targetLink, withDestinationURL: f.vault.appendingPathComponent("a.md"))
    #expect(throws: SnapshotError.unsafeExport) { try runtime.exportSnapshot(first.id, to: targetLink.path) }
    #if canImport(Darwin)
    #expect(try runtime.restoreSnapshot(first.id).state == "completed")
    #else
    #expect(throws: MutationError.self) { try runtime.restoreSnapshot(first.id) }
    #endif
    #expect(try Data(contentsOf: f.vault.appendingPathComponent("a.md")) == bytes)
    // Byte-wise comparison must distinguish canonically equivalent UTF-8.
    try f.write("a.md", "# Cafe\u{301}\r\noriginal\r\n")
    _ = try runtime.reconcile(at: start.addingTimeInterval(1))
    let second = try #require(runtime.snapshots(path: "a.md").last)
    #expect(try !runtime.compareSnapshots(first.id, second.id).changes.isEmpty)
    let object = f.state.appendingPathComponent("objects/" + first.contentHash)
    try Data(repeating: 0x78, count: bytes.count).write(to: object)
    let failedExport = f.root.appendingPathComponent("must-not-exist.md")
    #expect(throws: ObjectStoreError.corruptObject) { try runtime.inspectSnapshot(first.id) }
    #expect(throws: ObjectStoreError.corruptObject) { try runtime.exportSnapshot(first.id, to: failedExport.path) }
    #expect(!FileManager.default.fileExists(atPath: failedExport.path))
    // Restore never repairs history from the current source or overwrites it.
    #expect(throws: ObjectStoreError.corruptObject) { try runtime.restoreSnapshot(first.id) }
    #expect(try Data(contentsOf: output) == bytes)
}

@Test func legacyCatalogUpgradeRetainsRevisionsAndIncidentHistory() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let identity: Data
    do {
        let runtime = try VaultRuntime(configuration: f.configuration)
        identity = runtime.vaultID
        try runtime.shutdown()
    }
    let db = try f.database()
    // Fixture for an actual v4 operational catalog: no recovery tables existed.
    // These test-only drops remove empty new tables, never operational history.
    try db.execute("DROP TABLE mutation_journal")
    try db.execute("DROP TABLE recovery_snapshots")
    try db.execute("DROP TABLE snapshot_policy")
    try db.execute("PRAGMA user_version=4")
    let reader = try VaultReader(rootPath: f.vault.path)
    let store = try ObjectStore(directory: f.state.appendingPathComponent("objects").path)
    let path = try VaultPath("legacy.md")
    try f.write("legacy.md", "old history")
    let old = try ExternalCapture.capture(db: db, reader: reader, objects: store, vaultID: identity, path: path, maximumBytes: 1024, debounce: 0)
    try f.write("legacy.md", "good retained head")
    _ = try ExternalCapture.capture(db: db, reader: reader, objects: store, vaultID: identity, path: path, maximumBytes: 1024, debounce: 0)
    try Data([0xff]).write(to: f.vault.appendingPathComponent("legacy.md"))
    #expect(throws: ExternalCaptureError.invalidMarkdown) { try ExternalCapture.capture(db: db, reader: reader, objects: store, vaultID: identity, path: path, maximumBytes: 1024, debounce: 0) }
    let upgraded = try VaultRuntime(configuration: f.configuration)
    #expect(upgraded.vaultID == identity)
    #expect(try db.scalarText("PRAGMA user_version") == "6")
    #expect(try upgraded.status().revisions == 2 && upgraded.status().openIncidents == 1)
    let snapshot = try #require(upgraded.snapshots().first)
    #expect(snapshot.reason == "recovery" && snapshot.entryID == old.entryID)
    #expect(try upgraded.snapshotContents(snapshot.id) == Data("good retained head".utf8))
    #expect(try store.get(old.contentHash, maximumBytes: 1024) == Data("old history".utf8))
    #expect(try Data(contentsOf: f.vault.appendingPathComponent("legacy.md")) == Data([0xff]))
    #expect(try db.scalarText("SELECT count(*) FROM changes") == "2")
    try upgraded.shutdown()
}
