import Foundation
import Testing
@testable import AndesiteCore

@Test func selectionIsPathOnlyUntilExplicitOpenAndClose() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# One\nfirstunique\n")
    let root = f.root.appendingPathComponent("managed-states").path
    let marker = try VaultPathRegistry(vaultDirectory: f.vault.path)
    #expect(try marker.register())
    let planned = try VaultSession.plannedStateDirectory(
        vaultDirectory: f.vault.path, stateRoot: root)
    #expect(!FileManager.default.fileExists(atPath: planned))

    let session = try VaultSession(vaultDirectory: f.vault.path, stateRoot: root)
    #expect(session.stateDirectory == planned)
    #expect(FileManager.default.fileExists(atPath: planned + "/catalog.sqlite"))
    let first = try session.reconcile()
    #expect(first.discovered == 1 && first.revisionsCreated == 1)
    let id = try session.run { $0.vaultID }
    #expect(try session.run { try $0.search("firstunique").count } == 1)
    #expect(throws: ProcessLockError.unavailable) {
        try VaultSession(vaultDirectory: f.vault.path, stateRoot: root)
    }

    try session.close()
    try session.close()
    #expect(throws: VaultSessionError.closed) { try session.reconcile() }

    let reopened = try VaultSession(vaultDirectory: f.vault.path, stateRoot: root)
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
    let session = try VaultSession(vaultDirectory: f.vault.path, stateRoot: root)
    let id = try session.run { $0.vaultID }
    let sourceState = session.stateDirectory
    #expect(try session.reconcile().revisionsCreated == 1)
    let first = try #require(session.run { try $0.snapshots(path: "note.md").first })
    try session.close()

    let moved = f.root.appendingPathComponent("moved-vault")
    try FileManager.default.moveItem(at: f.vault, to: moved)
    #expect(try VaultSession.plannedStateDirectory(vaultDirectory: moved.path, stateRoot: root) == sourceState)
    let selected = try VaultPathRegistry(vaultDirectory: moved.path)
    #expect(try selected.storedPath() == f.vault.path)

    let restored = try VaultSession(vaultDirectory: moved.path, stateRoot: root)
    #expect(restored.stateDirectory == sourceState)
    #expect(try restored.run { $0.vaultID } == id)
    #expect(try restored.reconcile().revisionsCreated == 0)
    #expect(try restored.run { try $0.snapshots(path: "note.md").first?.id } == first.id)
    #expect(try selected.storedPath() == moved.path)
    try Data("# History\nsecondrevision\n".utf8).write(to: moved.appendingPathComponent("note.md"))
    #expect(try restored.reconcile().revisionsCreated == 1)
    #expect(try restored.run { try $0.status().revisions } == 2)
    try restored.close()

    let again = try VaultSession(vaultDirectory: moved.path, stateRoot: root)
    #expect(try again.run { $0.vaultID } == id)
    #expect(try again.run { try $0.status().revisions } == 2)
    try again.close()
}

@Test func copiedVaultMustNotSilentlyCreateNewHistoryOrTrustOldPath() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "important-before-copy")
    let root = f.root.appendingPathComponent("managed").path
    let original = try VaultSession(vaultDirectory: f.vault.path, stateRoot: root)
    let originalState = original.stateDirectory
    _ = try original.reconcile()
    try original.close()

    let clone = f.root.appendingPathComponent("clone")
    try FileManager.default.copyItem(at: f.vault, to: clone)
    let copied = try VaultPathRegistry(vaultDirectory: clone.path)
    #expect(try copied.storedPath() == f.vault.path)
    let newState = try VaultSession.plannedStateDirectory(vaultDirectory: clone.path, stateRoot: root)
    #expect(newState != originalState)
    #expect(throws: VaultSessionError.stateHistoryRequiresMigration) {
        try VaultSession(vaultDirectory: clone.path, stateRoot: root)
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
    let session = try VaultSession(vaultDirectory: moved.path, stateDirectory: f.state.path)
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
    let session = try VaultSession(vaultDirectory: f.vault.path, stateRoot: root)
    let reports = Reports()
    try session.startWatching(report: reports.add)
    #expect(eventually { reports.contains("watch-ready") })
    #expect(try session.run { try $0.status().revisions } == 1)
    try session.close()
    #expect(throws: VaultSessionError.closed) { try session.run { _ in } }
    let again = try VaultSession(vaultDirectory: f.vault.path, stateRoot: root)
    #expect(try again.run { try $0.status().revisions } == 1)
    try again.close()
}
