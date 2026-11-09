import Foundation
import Testing
@testable import AndesiteCore

@Test func selectionIsPathOnlyUntilExplicitOpenAndClose() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# One\nfirstunique\n")
    let root = f.root.appendingPathComponent("managed-states").path
    let marker = try VaultPathRegistry(vaultDirectory: f.vault.path)
    #expect(try marker.register())
    let planned = try Vault.plannedStateDirectory(
        vaultDirectory: f.vault.path, stateRoot: root)
    #expect(!FileManager.default.fileExists(atPath: planned))

    let session = try Vault(at: f.vault.path, options: .init(stateRoot: root, watch: false))
    #expect(session.stateDirectory == planned)
    #expect(FileManager.default.fileExists(atPath: planned + "/catalog.sqlite"))
    let first = try session.reconcile()
    #expect(first.discovered == 1 && first.revisionsCreated == 1)
    let id = try session.run { $0.vaultID }
    #expect(try session.run { try $0.search("firstunique").count } == 1)
    #expect(throws: ProcessLockError.unavailable) {
        try Vault(at: f.vault.path, options: .init(stateRoot: root, watch: false))
    }

    try session.close()
    try session.close()
    #expect(throws: VaultRuntimeError.closed) { try session.reconcile() }

    let reopened = try Vault(at: f.vault.path, options: .init(stateRoot: root, watch: false))
    #expect(try reopened.run { $0.vaultID } == id)
    #expect(try reopened.reconcile().revisionsCreated == 0)
    #expect(try reopened.run { try $0.status().revisions } == 1)
    try reopened.close()
    #expect(try marker.storedPath() == f.vault.path)
    #expect(try String(contentsOf: f.vault.appendingPathComponent("note.md"), encoding: .utf8) ==
            "# One\nfirstunique\n")
}

@Test func movedVaultKeepsSameStateAndHistoryWithoutReindexing() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# History\nfirstrevision\n")
    let root = f.root.appendingPathComponent("automatic-state").path
    let session = try Vault(at: f.vault.path, options: .init(stateRoot: root, watch: false))
    let id = try session.run { $0.vaultID }
    let sourceState = session.stateDirectory
    #expect(try session.reconcile().revisionsCreated == 1)
    let first = try #require(session.run { try $0.snapshots(path: "note.md").first })
    try session.close()

    let moved = f.root.appendingPathComponent("moved-vault")
    try FileManager.default.moveItem(at: f.vault, to: moved)
    #expect(try Vault.plannedStateDirectory(vaultDirectory: moved.path, stateRoot: root) == sourceState)
    let selected = try VaultPathRegistry(vaultDirectory: moved.path)
    #expect(try selected.storedPath() == f.vault.path)

    let restored = try Vault(at: moved.path, options: .init(stateRoot: root, watch: false))
    #expect(restored.stateDirectory == sourceState)
    #expect(try restored.run { $0.vaultID } == id)
    #expect(try restored.reconcile().revisionsCreated == 0)
    #expect(try restored.run { try $0.snapshots(path: "note.md").first?.id } == first.id)
    #expect(try selected.storedPath() == moved.path)
    try Data("# History\nsecondrevision\n".utf8).write(to: moved.appendingPathComponent("note.md"))
    #expect(try restored.reconcile().revisionsCreated == 1)
    #expect(try restored.run { try $0.status().revisions } == 2)
    try restored.close()

    let again = try Vault(at: moved.path, options: .init(stateRoot: root, watch: false))
    #expect(try again.run { $0.vaultID } == id)
    #expect(try again.run { try $0.status().revisions } == 2)
    try again.close()
}

@Test func copiedVaultMustNotSilentlyCreateNewHistoryOrTrustOldPath() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "important-before-copy")
    let root = f.root.appendingPathComponent("managed").path
    let original = try Vault(at: f.vault.path, options: .init(stateRoot: root, watch: false))
    let originalState = original.stateDirectory
    _ = try original.reconcile()
    try original.close()

    let clone = f.root.appendingPathComponent("clone")
    try FileManager.default.copyItem(at: f.vault, to: clone)
    let copied = try VaultPathRegistry(vaultDirectory: clone.path)
    #expect(try copied.storedPath() == f.vault.path)
    let newState = try Vault.plannedStateDirectory(vaultDirectory: clone.path, stateRoot: root)
    #expect(newState != originalState)
    #expect(throws: VaultOpenError.stateHistoryRequiresMigration) {
        try Vault(at: clone.path, options: .init(stateRoot: root, watch: false))
    }
    #expect(try copied.storedPath() == f.vault.path)
    #expect(!FileManager.default.fileExists(atPath: newState))
    #expect(FileManager.default.fileExists(atPath: originalState + "/catalog.sqlite"))
    #expect(try String(contentsOf: clone.appendingPathComponent("note.md"), encoding: .utf8) ==
            "important-before-copy")
}

@Test func legacyManualStateCanBeReusedAfterSameVolumeMove() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# Legacy\nkeepthese\n")
    let marker = try VaultPathRegistry(vaultDirectory: f.vault.path)
    #expect(try marker.register())
    let legacy = try VaultRuntime(configuration: f.configuration)
    _ = try legacy.reconcile()
    let previousID = legacy.vaultID
    try legacy.shutdown()

    let moved = f.root.appendingPathComponent("renamed")
    try FileManager.default.moveItem(at: f.vault, to: moved)
    let session = try Vault(at: moved.path, options: .init(stateDirectory: f.state.path, watch: false))
    #expect(try session.run { $0.vaultID } == previousID)
    #expect(try session.reconcile().revisionsCreated == 0)
    #expect(try session.run { try $0.search("keepthese").count } == 1)
    try session.close()
    #expect(try VaultPathRegistry(vaultDirectory: moved.path).storedPath() == moved.path)
}

@Test func sessionWatchStartsThenClosesWithoutLeakingStateLock() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# Watched\nwatchuniquetoken\n")
    let root = f.root.appendingPathComponent("states").path
    let session = try Vault(at: f.vault.path, options: .init(stateRoot: root, watch: false))
    let reports = Reports()
    try session.startWatching(report: reports.add)
    #expect(eventually { reports.contains("watch-ready") })
    #expect(try session.run { try $0.status().revisions } == 1)
    try session.close()
    #expect(throws: VaultRuntimeError.closed) { try session.run { _ in } }
    let again = try Vault(at: f.vault.path, options: .init(stateRoot: root, watch: false))
    #expect(try again.run { try $0.status().revisions } == 1)
    try again.close()
}

private func writeNotes(_ f: RuntimeFixture, _ count: Int) throws {
    for i in 0..<count { try f.write("n\(i).md", "# Note \(i)\nbody \(i) [[n\((i + 1) % count)]]\n") }
}

/// Polls until a scan has committed some but not all of `total` files,
/// which proves these reads ran in the middle of it.
private func waitUntilScanIsHalfway(_ vault: Vault, total: Int) async throws -> Bool {
    for _ in 0..<2000 {
        let entries = try await vault.status().entries
        if entries > 0 && entries < total { return true }
        if entries >= total { return false }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
}

@Test func readsAreServedInsideALongBackgroundScan() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try writeNotes(f, 1000)
    let vault = try f.open()
    let scan = Task { try await vault.refresh() }
    #expect(try await waitUntilScanIsHalfway(vault, total: 1000))
    // Catalog writes are refused inside a read.
    await #expect(throws: SQLiteFailure.self) { try await vault.perform(.read) { try $0.create("x.md", Data()) } }
    #expect(try await scan.value.revisionsCreated == 1000)
    #expect(try await vault.search("body").count == 50)
    try vault.close()
}

@Test func aUserWriteInterruptsTheWatcherScanWhichThenCompletes() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try writeNotes(f, 1000)
    let reports = Reports()
    let vault = try Vault(at: f.vault.path, options: .init(stateDirectory: f.state.path, report: reports.add))
    #expect(try await waitUntilScanIsHalfway(vault, total: 1000))
    let created = try await vault.create("new.md", "# New\n[[n1]]\n")
    // Had the write waited for the scan, every note would be indexed by now.
    #expect(try await vault.status().entries < 1001)
    #expect(try eventually { reports.contains("watch-ready") }, "reports=\(reports.all)")
    let status = try await vault.status()
    #expect(status.state == "ready" && status.entries == 1001 && status.revisions == 1001)
    #expect(try await vault.links("n1.md", direction: .incoming).mentions.map(\.sourcePath).sorted() == ["n0.md", "new.md"])
    try await vault.update("new.md", "# New\n[[n2]]\n", revision: created.revisionID)
    #expect(try await vault.read("new.md").content == Data("# New\n[[n2]]\n".utf8))
    try vault.close()
}
