import Foundation
import Testing
@testable import AndesiteCore

struct RuntimeFixture {
    let root: URL
    let vault: URL
    let state: URL
    var configuration: VaultConfiguration { VaultConfiguration(vaultDirectory: vault.path, stateDirectory: state.path, debounce: 0) }
    init() throws {
        let temp = FileManager.default.temporaryDirectory.path
        #if canImport(Darwin)
        let canonical = temp.hasPrefix("/var/") ? "/private" + temp : temp
        #else
        let canonical = temp
        #endif
        root = URL(fileURLWithPath: canonical).appendingPathComponent(UUID().uuidString)
        vault = root.appendingPathComponent("vault"); state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: vault.appendingPathComponent(name)) }
    /// A `Vault` on this fixture's state, without the watcher unless asked.
    func open(watch: Bool = false) throws -> Vault {
        try Vault(at: vault.path, options: .init(stateDirectory: state.path, watch: watch))
    }
}

extension Vault {
    /// A blocking scan, for tests.
    @discardableResult
    func reconcile() throws -> ReconciliationReport { try run(.background) { try $0.reconcile() } }
}

extension VaultRuntime {
    /// Scans, then searches the index whatever its state.
    func scanAndSearch(_ phrase: String) throws -> [SearchIndexHit] {
        _ = try reconcile()
        return try SearchIndex.search(db: requireOpen().db, vaultID: vaultID, phrase: phrase, limit: 50)
    }
}

@Test func integratedLifecycleAndUnicode() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let original = "# First\r\noldword\r\n"
    try f.write("노트.md", original)
    let runtime = try VaultRuntime(configuration: f.configuration)
    let id = runtime.vaultID
    #expect(throws: ProcessLockError.unavailable) { try VaultRuntime(configuration: f.configuration) }
    #expect(try runtime.reconcile().revisionsCreated == 1)
    let first = try #require(runtime.scanAndSearch("oldword").first)
    #expect(try runtime.reconcile().unchanged == 1)
    try f.write("new.MD", "# Another\ndiscovery")
    #expect(try runtime.reconcile().revisionsCreated == 1)
    try f.write("노트.md", "# Second\nnewword")
    #expect(try runtime.scanAndSearch("oldword").isEmpty)
    let second = try #require(runtime.scanAndSearch("newword").first)
    #expect(first.entryID == second.entryID && first.revisionID != second.revisionID)
    #expect(try runtime.status().revisions == 3)
    try runtime.shutdown()
    let reopened = try VaultRuntime(configuration: f.configuration)
    #expect(reopened.vaultID == id)
    #expect(try reopened.scanAndSearch("newword").first == second)
    #expect(try reopened.status().revisions == 3)
    let store = try ObjectStore(directory: f.state.appendingPathComponent("objects").path)
    #expect(try store.get(ObjectStore.hash(Data(original.utf8)), maximumBytes: 1024) == Data(original.utf8))
    #expect(try String(contentsOf: f.vault.appendingPathComponent("노트.md"), encoding: .utf8) == "# Second\nnewword")
    try reopened.shutdown()
    #expect(throws: VaultRuntimeError.closed) { try reopened.reconcile() }
}

@Test func integratedFailureRetryAndObjectIntegrity() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("a.md", "# Initial\nhello")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    // Controlled fault injection only: production callers never get the connection.
    let db = try SQLiteConnection(path: f.state.appendingPathComponent("catalog.sqlite").path)
    try db.execute("CREATE TRIGGER injected BEFORE INSERT ON revisions BEGIN SELECT RAISE(ABORT, 'injected'); END")
    try f.write("a.md", "# Updated\nchanged")
    #expect(throws: SQLiteFailure.self) { try runtime.reconcile() }
    #expect(try runtime.status().revisions == 1)
    #expect(try runtime.status().state == "scanFailed")
    #expect(throws: SQLiteFailure.self) { try runtime.scanAndSearch("hello") }
    let orphanHash = ObjectStore.hash(Data("# Updated\nchanged".utf8))
    let orphanStore = try ObjectStore(directory: f.state.appendingPathComponent("objects").path)
    #expect(try orphanStore.get(orphanHash, maximumBytes: 1024) == Data("# Updated\nchanged".utf8))
    #expect(try db.queryValues("SELECT count(*) FROM objects WHERE lower(hex(hash))=?", bindings: [.text(orphanHash)]) == [[.integer(0)]])
    try db.execute("DROP TRIGGER injected")
    try runtime.shutdown()
    let retry = try VaultRuntime(configuration: f.configuration)
    #expect(try retry.reconcile().revisionsCreated == 1)
    #expect(try retry.status().revisions == 2)
    #expect(try retry.scanAndSearch("changed").count == 1)
    try Data([0xff]).write(to: f.vault.appendingPathComponent("a.md"))
    #expect(try retry.reconcile().invalidMarkdown == 1)
    #expect(try retry.scanAndSearch("changed").isEmpty)
    #expect(try retry.status().openIncidents == 1)
    #expect(try retry.status().revisions == 2)
    try retry.shutdown()
    let quarantineRestart = try VaultRuntime(configuration: f.configuration)
    #expect(try quarantineRestart.scanAndSearch("changed").isEmpty)
    #expect(try quarantineRestart.status().openIncidents == 1)
    try f.write("a.md", "# Updated\nchanged")
    #expect(try quarantineRestart.scanAndSearch("changed").count == 1)
    #expect(try quarantineRestart.status().openIncidents == 0)
    try quarantineRestart.shutdown()
    let hash = ObjectStore.hash(Data("# Initial\nhello".utf8))
    let object = f.state.appendingPathComponent("objects/" + hash)
    let currentBytes = try Data(contentsOf: f.vault.appendingPathComponent("a.md"))
    try Data("corrupt".utf8).write(to: object)
    #expect(throws: (any Error).self) { try VaultRuntime(configuration: f.configuration) }
    #expect(try Data(contentsOf: f.vault.appendingPathComponent("a.md")) == currentBytes)
    try FileManager.default.removeItem(at: object)
    #expect(throws: (any Error).self) { try VaultRuntime(configuration: f.configuration) }
    #expect(try Data(contentsOf: f.vault.appendingPathComponent("a.md")) == currentBytes)
}

@Test func integratedUnsafeNamespaceAndConservativeMoves() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("a.md", "# Kept\nhistory")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    try FileManager.default.moveItem(at: f.vault.appendingPathComponent("a.md"), to: f.vault.appendingPathComponent("moved.md"))
    let move = try runtime.reconcile()
    #expect(move.renamed == 1 && move.deleted == 0)
    #expect(try runtime.status().revisions == 2)
    try FileManager.default.moveItem(at: f.vault.appendingPathComponent("moved.md"), to: f.vault.appendingPathComponent("a.md"))
    // Symlinks are never followed or indexed; the scan itself proceeds.
    try FileManager.default.createSymbolicLink(atPath: f.vault.appendingPathComponent("link.md").path, withDestinationPath: f.vault.appendingPathComponent("a.md").path)
    #expect(try runtime.scanAndSearch("history").map(\.path) == ["a.md"])
    try FileManager.default.removeItem(at: f.vault.appendingPathComponent("link.md"))
    try FileManager.default.createDirectory(at: f.vault.appendingPathComponent("Upper"), withIntermediateDirectories: false)
    try f.write("Upper/one.md", "one")
    // Same portable namespace despite distinct filenames on every host.
    try f.write("a.MD", "collision")
    // On case-insensitive filesystems this replaces a.md, which is a supported edit.
    let names = try FileManager.default.contentsOfDirectory(atPath: f.vault.path)
    if names.contains("a.md") && names.contains("a.MD") {
        #expect(throws: VaultReadError.invalidPath) { try runtime.reconcile() }
    }
    #expect(throws: VaultReadError.invalidPath) { try VaultPath("../escape.md") }
    #expect(try VaultPath("Café.md").portabilityKey == VaultPath("CAFE\u{301}.MD").portabilityKey)
    let displaced = f.root.appendingPathComponent("displaced")
    try FileManager.default.moveItem(at: f.vault, to: displaced)
    try FileManager.default.createDirectory(at: f.vault, withIntermediateDirectories: false)
    #expect(throws: VaultReadError.unstable) { try runtime.scanAndSearch("history") }
    try runtime.shutdown()
    #expect(throws: VaultRuntimeError.identityMismatch) { try VaultRuntime(configuration: f.configuration) }
    let unsafe = VaultConfiguration(vaultDirectory: f.vault.path, stateDirectory: f.vault.path)
    #expect(throws: (any Error).self) { try VaultRuntime(configuration: unsafe) }
}

@Test func integratedPartialScanIndexRecoveryAndSchemaRefusal() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("a.md", "# Before\noldtoken")
    try f.write("z.md", "# Last\nlasttoken")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let db = try SQLiteConnection(path: f.state.appendingPathComponent("catalog.sqlite").path)
    // Fail the derived-index transaction *after* the first file's revision commits.
    try db.execute("CREATE TRIGGER index_fault BEFORE INSERT ON document_metadata BEGIN SELECT RAISE(ABORT, 'index fault'); END")
    try f.write("a.md", "# After\nnewtoken")
    try f.write("b.md", "# Discovered\nnewfiletoken")
    #expect(throws: SQLiteFailure.self) { try runtime.reconcile() }
    // Both captures committed (one batch); only their index failed.
    #expect(try runtime.status().revisions == 4)
    #expect(try db.queryValues("SELECT count(*) FROM changes") == [[.integer(4)]])
    // The old FTS row survives the rollback but cannot pass the current-head join.
    #expect(try SearchIndex.search(db: db, vaultID: runtime.vaultID, phrase: "oldtoken", limit: 10).isEmpty)
    #expect(try SearchIndex.search(db: db, vaultID: Data(repeating: 0x55, count: 16), phrase: "lasttoken", limit: 10).isEmpty)
    #expect(throws: SQLiteFailure.self) { try runtime.scanAndSearch("lasttoken") }
    try runtime.shutdown()
    let restarted = try VaultRuntime(configuration: f.configuration)
    #expect(try restarted.status().state == "scanRequired")
    #expect(throws: SQLiteFailure.self) { try restarted.scanAndSearch("oldtoken") }
    try db.execute("DROP TRIGGER index_fault")
    let recovered = try restarted.reconcile()
    // Nothing is left to capture; the scan repairs the missing indexes
    // from stored content.
    #expect(recovered.revisionsCreated == 0 && recovered.unchanged == 3, "\(recovered)")
    #expect(try restarted.search("newtoken").count == 1)
    #expect(try restarted.search("oldtoken").isEmpty)
    #expect(try restarted.search("newfiletoken").count == 1)
    #expect(try restarted.status().revisions == 4)
    #expect(try db.queryValues("SELECT next_seq FROM vaults") == [[.integer(5)]])
    // An incomplete enumeration rejects the whole attempt; it never publishes deletion.
    try FileManager.default.removeItem(at: f.vault.appendingPathComponent("z.md"))
    let locked = f.vault.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0])
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
    #expect(throws: VaultReadError.unsafeFile) { try restarted.reconcile() }
    #expect(try db.queryValues("SELECT count(*) FROM entries WHERE state='live'") == [[.integer(3)]])
    #expect(try db.queryValues("SELECT count(*) FROM changes") == [[.integer(4)]])
    #expect(try db.queryValues("SELECT count(*) FROM revisions WHERE deleted=1") == [[.integer(0)]])
    try restarted.shutdown()
    // An unknown newer schema is never migrated backwards, even after a failed scan.
    try db.execute("PRAGMA user_version=999")
    #expect(throws: CatalogMigrationError.unsupportedVersion(999)) { try VaultRuntime(configuration: f.configuration) }
    #expect(try db.scalarText("PRAGMA user_version") == "999")
    #expect(try Data(contentsOf: f.vault.appendingPathComponent("a.md")) == Data("# After\nnewtoken".utf8))
    #expect(try Data(contentsOf: f.vault.appendingPathComponent("b.md")) == Data("# Discovered\nnewfiletoken".utf8))
    try db.execute("PRAGMA user_version=10")
    // A failed startup did not retain ownership.
    let finalOpen = try VaultRuntime(configuration: f.configuration)
    try finalOpen.shutdown()
}
