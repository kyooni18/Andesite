import Foundation
import Testing
@testable import AndesiteCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private extension RuntimeFixture {
    func catalog() throws -> SQLiteConnection { try SQLiteConnection(path: state.appendingPathComponent("catalog.sqlite").path) }
    func contents(_ name: String = "note.md") throws -> Data { try Data(contentsOf: vault.appendingPathComponent(name)) }
    func seeded() throws -> (VaultRuntime, RecoverySnapshot) {
        try write("note.md", "# Ancient\nolduniquetoken\r\n")
        let runtime = try VaultRuntime(configuration: configuration)
        _ = try runtime.reconcile()
        let snapshot = try #require(runtime.snapshots().first)
        try write("note.md", "# Current\nnewuniquetoken\n")
        _ = try runtime.reconcile()
        return (runtime, snapshot)
    }
}

#if canImport(Darwin)
@Test func restorePreservesPreimageLineageSearchAndMetadata() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let (runtime, old) = try f.seeded()
    let db = try f.catalog()
    let previousHead = try db.queryValues("SELECT head_revision FROM entries")[0][0]
    let original = try f.contents()
    #expect(chmod(f.vault.appendingPathComponent("note.md").path, 0o640) == 0)
    // Metadata changes are external modifications too; explicitly recapture.
    _ = try runtime.reconcile()
    let xattrName = "com.andesite.test"
    let source = open(f.vault.appendingPathComponent("note.md").path, O_RDONLY)
    #expect(source >= 0)
    let attribute = Data("metadata payload".utf8)
    #expect(attribute.withUnsafeBytes { fsetxattr(source, xattrName, $0.baseAddress, $0.count, 0, 0) } == 0)
    close(source)
    _ = try runtime.reconcile()
    let operation = try runtime.restoreSnapshot(old.id)
    #expect(operation.state == "completed" && operation.entryID == old.entryID)
    #expect(try runtime.snapshotContents(operation.preimageID) == original)
    #expect(try f.contents() == runtime.snapshotContents(old.id))
    #expect(try db.queryValues("SELECT parent1,origin FROM revisions WHERE revision_id=?", bindings: [.blob(operation.revisionID)]) == [[previousHead, .text("restore")]])
    #expect(try runtime.search("olduniquetoken").count == 1)
    #expect(try runtime.search("newuniquetoken").isEmpty)
    #expect(try db.scalarText("SELECT count(*) FROM revisions") == "3")
    #expect(try db.scalarText("SELECT count(*) FROM changes") == "3")
    var s = stat()
    #expect(lstat(f.vault.appendingPathComponent("note.md").path, &s) == 0 && s.st_mode & 0o777 == 0o640)
    let restored = open(f.vault.appendingPathComponent("note.md").path, O_RDONLY)
    var buffer = [UInt8](repeating: 0, count: 64)
    let n = fgetxattr(restored, xattrName, &buffer, buffer.count, 0, 0)
    close(restored)
    #expect(n == attribute.count && Data(buffer.prefix(max(0, n))) == attribute)
    #expect(try f.contents(operation.artifact) == original)
    // Every explicit request (including identical content) appends a new child;
    // recovery, in contrast, never duplicates the same journal revision.
    let again = try runtime.restoreSnapshot(old.id)
    #expect(again.revisionID != operation.revisionID)
    #expect(try db.queryValues("SELECT parent1 FROM revisions WHERE revision_id=?", bindings: [.blob(again.revisionID)]) == [[.blob(operation.revisionID)]])
    #expect(try runtime.snapshotContents(again.preimageID) == runtime.snapshotContents(old.id))
    #expect(try db.scalarText("SELECT count(*) FROM revisions") == "4")
    #expect(try runtime.snapshots().count == 4)
    #expect(try db.scalarText("PRAGMA integrity_check") == "ok")
    #expect(try db.queryValues("PRAGMA foreign_key_check").isEmpty)
    // A historical snapshot follows its document identity to the current path,
    // including nested Unicode names; it never recreates the historical path.
    let nested = f.vault.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    try FileManager.default.moveItem(at: f.vault.appendingPathComponent("note.md"), to: nested.appendingPathComponent("노트.MD"))
    #expect(try runtime.reconcile().renamed == 1)
    let movedRestore = try runtime.restoreSnapshot(old.id)
    #expect(movedRestore.path == "nested/노트.MD" && movedRestore.entryID == old.entryID)
    #expect(try f.contents("nested/노트.MD") == runtime.snapshotContents(old.id))
    #expect(!FileManager.default.fileExists(atPath: f.vault.appendingPathComponent("note.md").path))
    try runtime.shutdown()
    let restarted = try VaultRuntime(configuration: f.configuration)
    #expect(try restarted.reconcile().revisionsCreated == 0)
    #expect(try restarted.status().revisions == 6)
    #expect(try restarted.mutationOperations().allSatisfy { $0.state == "completed" })
    try restarted.shutdown()
}

@Test func restoreRejectsExternalChangesUnsafePathsAndDatabaseLocks() throws {
    for scenario in ["edit", "same-bytes-replacement", "symlink", "parent-replacement", "before-exchange-edit", "lock-before-intent", "lock-before-exchange"] {
        let f = try RuntimeFixture(); defer { f.clean() }
        let (runtime, snapshot) = try f.seeded()
        let db = try f.catalog()
        let before = try f.contents()
        var heldLock = false
        switch scenario {
        case "edit": try f.write("note.md", "external edit must survive")
        case "same-bytes-replacement": try before.write(to: f.vault.appendingPathComponent("note.md"), options: .atomic)
        case "symlink":
            let outside = f.root.appendingPathComponent("outside.md")
            try Data("unrelated".utf8).write(to: outside)
            try FileManager.default.removeItem(at: f.vault.appendingPathComponent("note.md"))
            try FileManager.default.createSymbolicLink(at: f.vault.appendingPathComponent("note.md"), withDestinationURL: outside)
        case "parent-replacement":
            runtime.mutationFault = { point in
                if point == "staged" {
                    try FileManager.default.moveItem(at: f.vault, to: f.root.appendingPathComponent("displaced-vault"))
                    try FileManager.default.createDirectory(at: f.vault, withIntermediateDirectories: false)
                    try f.write("note.md", "unrelated replacement directory")
                }
            }
        case "before-exchange-edit":
            runtime.mutationFault = { point in if point == "before-exchange" { try f.write("note.md", "racing external edit") } }
        case "lock-before-intent": try db.execute("BEGIN IMMEDIATE"); heldLock = true
        case "lock-before-exchange":
            runtime.mutationFault = { point in if point == "staged" { try db.execute("BEGIN IMMEDIATE"); heldLock = true } }
        default: break
        }
        #expect(throws: (any Error).self) { try runtime.restoreSnapshot(snapshot.id) }
        if heldLock { try db.execute("ROLLBACK") }
        runtime.mutationFault = nil
        if scenario == "symlink" { #expect(try String(contentsOf: f.root.appendingPathComponent("outside.md"), encoding: .utf8) == "unrelated") }
        else if scenario == "parent-replacement" { #expect(try f.contents() == Data("unrelated replacement directory".utf8)) }
        else if scenario == "edit" { #expect(try f.contents() == Data("external edit must survive".utf8)) }
        else if scenario == "before-exchange-edit" { #expect(try f.contents() == Data("racing external edit".utf8)) }
        else { #expect(try f.contents() == before) }
        #expect(try db.scalarText("SELECT count(*) FROM revisions") == "2")
        #expect(try runtime.snapshotContents(snapshot.id) == Data("# Ancient\nolduniquetoken\r\n".utf8))
        try runtime.shutdown()
    }
}

private func killRestore(_ f: RuntimeFixture, snapshot: RecoverySnapshot, at point: String) throws {
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/andesite-server")
    let child = Process()
    child.executableURL = executable
    child.arguments = ["snapshot-restore", "--vault", f.vault.path, "--state", f.state.path, MutationJournal.hex(snapshot.id), "--in-place"]
    var env = ProcessInfo.processInfo.environment
    env["ANDESITE_TEST_FAULTS"] = "1"; env["ANDESITE_TEST_KILL_POINT"] = point
    child.environment = env
    let output = Pipe(); child.standardOutput = output; child.standardError = output
    try child.run(); child.waitUntilExit()
    let diagnostic = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "\(point): \(diagnostic)")
}

@Test func journalSIGKILLBoundariesAndIdempotentRecovery() throws {
    let points = ["before-preimage", "preimage-written", "preimage-preserved", "intent-written", "intent-committed", "stage-created", "stage-written", "staged", "before-exchange", "exchanged", "published", "before-catalog", "catalog-written", "catalogued", "before-completion", "completed"]
    for (i, point) in points.enumerated() {
        let f = try RuntimeFixture(); defer { f.clean() }
        let (runtime, snapshot) = try f.seeded()
        let preimage = try f.contents()
        try runtime.shutdown()
        try killRestore(f, snapshot: snapshot, at: point)
        let visible = try f.contents()
        let published = i >= points.firstIndex(of: "exchanged")!
        #expect(visible == (published ? Data("# Ancient\nolduniquetoken\r\n".utf8) : preimage), "\(point)")
        let recovered = try VaultRuntime(configuration: f.configuration)
        let operations = try recovered.mutationOperations()
        if i < 4 { #expect(operations.isEmpty) }
        else {
            let operation = try #require(operations.first)
            let expected = (point == "stage-created" || point == "stage-written") ? "quarantined" : (published ? "completed" : "cancelled")
            #expect(operation.state == expected, "\(point): \(operation.state)")
            #expect(try recovered.snapshotContents(operation.preimageID) == preimage)
            if expected == "quarantined" { #expect(throws: MutationError.self) { try recovered.reconcile() } }
            else { #expect(try recovered.reconcile().revisionsCreated == 0) }
        }
        let db = try f.catalog()
        let revisions = try db.scalarText("SELECT count(*) FROM revisions")
        let snapshots = try db.scalarText("SELECT count(*) FROM recovery_snapshots")
        #expect(revisions == (published ? "3" : "2"), "\(point)")
        #expect(try db.scalarText("SELECT count(*) FROM changes") == revisions)
        #expect(try db.scalarText("PRAGMA integrity_check") == "ok")
        #expect(try db.queryValues("PRAGMA foreign_key_check").isEmpty)
        try recovered.shutdown()
        let secondRestart = try VaultRuntime(configuration: f.configuration)
        #expect(try db.scalarText("SELECT count(*) FROM revisions") == revisions)
        #expect(try db.scalarText("SELECT count(*) FROM recovery_snapshots") == snapshots)
        #expect(try f.contents() == visible)
        try secondRestart.shutdown()
    }
}

@Test func journalQuarantinesPostPublicationEditsWithoutRollback() throws {
    for mode in ["visible-target", "displaced-open-fd", "catalog-trigger"] {
        let f = try RuntimeFixture(); defer { f.clean() }
        var (runtime, snapshot) = try f.seeded()
        let before = try f.contents()
        let heldFD = mode == "displaced-open-fd" ? open(f.vault.appendingPathComponent("note.md").path, O_WRONLY | O_CLOEXEC) : -1
        defer { if heldFD >= 0 { close(heldFD) } }
        if mode == "catalog-trigger" {
            let db = try f.catalog()
            try db.execute("CREATE TRIGGER journal_index_fault BEFORE INSERT ON document_metadata BEGIN SELECT RAISE(ABORT,'injected failure'); END")
            #expect(throws: SQLiteFailure.self) { try runtime.restoreSnapshot(snapshot.id) }
            #expect(try runtime.mutationOperations().first?.state == "published")
            #expect(try db.scalarText("SELECT count(*) FROM revisions") == "2")
            try db.execute("DROP TRIGGER journal_index_fault")
        } else {
            try runtime.shutdown()
            try killRestore(f, snapshot: snapshot, at: "exchanged")
            if mode == "visible-target" { try f.write("note.md", "newer external content") }
            else {
                let late = Data("late write to displaced inode".utf8)
                #expect(heldFD >= 0 && ftruncate(heldFD, 0) == 0)
                #expect(late.withUnsafeBytes { write(heldFD, $0.baseAddress, $0.count) } == late.count)
                #expect(fsync(heldFD) == 0)
            }
        }
        try runtime.shutdown()
        if mode == "catalog-trigger" {
            // Kill again DURING startup redo, with the new revision and FTS rows
            // uncommitted. A third process must still allocate no duplicates.
            try killRestore(f, snapshot: snapshot, at: "catalog-written")
        }
        runtime = try VaultRuntime(configuration: f.configuration)
        let operation = try #require(runtime.mutationOperations().first)
        if mode == "catalog-trigger" {
            #expect(operation.state == "completed")
            #expect(try runtime.status().revisions == 3)
            #expect(try runtime.search("olduniquetoken").count == 1)
        } else {
            #expect(operation.state == "quarantined")
            #expect(throws: MutationError.self) { try runtime.reconcile() }
            #expect(try runtime.status().revisions == 2)
            if mode == "visible-target" { #expect(try f.contents() == Data("newer external content".utf8)) }
            else { #expect(try f.contents(operation.artifact) == Data("late write to displaced inode".utf8)) }
        }
        #expect(try runtime.snapshotContents(operation.preimageID) == before)
        #expect(try runtime.snapshotContents(snapshot.id) == Data("# Ancient\nolduniquetoken\r\n".utf8))
        try runtime.shutdown()
    }
}
#endif

@Test func restorationRejectsMissingImmutableObjectsWithoutLosingHistory() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let (runtime, snapshot) = try f.seeded()
    let current = try f.contents()
    let db = try f.catalog()
    try FileManager.default.removeItem(at: f.state.appendingPathComponent("objects/" + snapshot.contentHash))
    #expect(throws: ObjectStoreError.self) { try runtime.restoreSnapshot(snapshot.id) }
    #expect(try f.contents() == current)
    #expect(try db.scalarText("SELECT count(*) FROM revisions") == "2")
    #expect(try db.scalarText("SELECT count(*) FROM recovery_snapshots") == "1")
    #expect(try db.scalarText("SELECT count(*) FROM mutation_journal") == "0")
    // shutdown surfaces corruption but always releases the process lock.
    #expect(throws: ObjectStoreError.self) { try runtime.shutdown() }
    let ownership = try ProcessLock(stateDirectory: f.state.path)
    withExtendedLifetime(ownership) {}
}
