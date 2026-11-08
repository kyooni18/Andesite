import Foundation
import Testing
@testable import AndesiteCore

@Test func embeddedBackendExportsChangesAndRemoteInboxPreservesHistoryWithoutApplying() throws {
    let local = try RuntimeFixture(); defer { local.clean() }
    let remote = try RuntimeFixture(); defer { remote.clean() }
    try local.write("note.md", "# Original\nLocal first version\n")
    try remote.write("server.md", "# Server\nRemote stays unchanged\n")
    let source = try VaultRuntime(configuration: local.configuration)
    let destination = try VaultRuntime(configuration: remote.configuration)
    _ = try source.reconcile()
    _ = try destination.reconcile()
    let api = source
    let server = destination
    let peer = "server-archive"

    #expect(try api.syncAcknowledgedSequence(peer: peer) == 0)
    let first = try api.syncChanges(after: 0)
    #expect(first.protocolVersion == 1)
    #expect(first.after == 0 && first.changes.count == 1)
    #expect(first.headSequence == first.through)
    #expect(first.sourceVault != AndesiteSyncWire.hex(server.vaultID))
    let original = try #require(first.changes.first)
    #expect(try AndesiteSyncWire.validateEvent(original) ==
            Data("# Original\nLocal first version\n".utf8))
    let data = try AndesiteSyncWire.encode(first)
    #expect(try AndesiteSyncWire.decode(AndesiteSyncChangeBatch.self, bytes: data) == first)

    let accepted = try server.receiveSyncChanges(first)
    #expect(accepted.acknowledgedSequence == first.through)
    #expect(accepted.accepted == 1 && !accepted.replay)
    let replay = try server.receiveSyncChanges(first)
    #expect(replay.accepted == 0 && replay.replay)
    #expect(try server.syncInboxChanges(
        sourceVault: first.sourceVault, sourceEpoch: first.sourceEpoch,
        after: 0, limit: 8) == first)
    let receivedSources = try server.syncInbox()
    #expect(receivedSources["total"] as? Int64 == 1)
    try api.acknowledgeSync(peer: peer, batch: first, receipt: accepted)
    #expect(try api.syncAcknowledgedSequence(peer: peer) == first.through)
    #expect(try server.documents().total == 1)
    #expect(try server.documents().documents.first?.path == "server.md")
    #expect(try Data(contentsOf: remote.vault.appendingPathComponent("server.md"))
            == Data("# Server\nRemote stays unchanged\n".utf8))

    let history = try #require(source.snapshots(path: "note.md").first)
    let snapshot = try api.syncSnapshot(history.id)
    #expect(try AndesiteSyncWire.validateSnapshot(snapshot) ==
            Data("# Original\nLocal first version\n".utf8))
    #expect(try api.pendingSyncSnapshots(peer: peer).contains(history.id))
    #expect(try server.receiveSyncSnapshot(snapshot))
    #expect(try !server.receiveSyncSnapshot(snapshot))
    #expect(try server.syncInboxSnapshot(
        sourceVault: first.sourceVault, sourceEpoch: first.sourceEpoch,
        snapshotID: snapshot.id) == snapshot)
    let summary = try server.syncInboxSnapshotList(
        sourceVault: first.sourceVault, sourceEpoch: first.sourceEpoch)
    #expect(summary["total"] as? Int64 == 1)
    var broken = snapshot
    // Tamper through encoded JSON, preserving its metadata identifiers.
    var object = try #require(JSONSerialization.jsonObject(
        with: AndesiteSyncWire.encode(snapshot)) as? [String: Any])
    object["contentBase64"] = Data("not the snapshot".utf8).base64EncodedString()
    broken = try AndesiteSyncWire.decode(
        AndesiteSyncSnapshot.self,
        bytes: JSONSerialization.data(withJSONObject: object))
    #expect(throws: AndesiteSyncError.contentMismatch) {
        try server.receiveSyncSnapshot(broken)
    }
    try api.acknowledgeSyncSnapshot(peer: peer, snapshot: snapshot)
    #expect(try api.pendingSyncSnapshots(peer: peer).isEmpty)

    let note = try #require(try source.documents().documents.first)
    try local.write("note.md", "# Updated\nLocal second version\n")
    _ = try source.reconcile()
    let second = try api.syncChanges(after: first.through)
    #expect(second.changes.count == 1 && second.through == first.through + 1)
    let latest = try server.receiveSyncChanges(second)
    try api.acknowledgeSync(peer: peer, batch: second, receipt: latest)
    #expect(try api.syncAcknowledgedSequence(peer: peer) == second.through)
    for id in try api.pendingSyncSnapshots(peer: peer) {
        let nextSnapshot = try api.syncSnapshot(id)
        _ = try server.receiveSyncSnapshot(nextSnapshot)
        try api.acknowledgeSyncSnapshot(peer: peer, snapshot: nextSnapshot)
    }
    #expect(try api.pendingSyncSnapshots(peer: peer).isEmpty)
    #expect(try server.documents().total == 1)
    #expect(try source.inspectDocument(note.id).revisionID != note.revisionID)

    let changed = AndesiteSyncChange(
        sequence: first.changes[0].sequence,
        eventJSON: first.changes[0].eventJSON,
        contentSHA256: first.changes[0].contentSHA256,
        contentBase64: Data("malicious replacement".utf8).base64EncodedString())
    let tampered = AndesiteSyncChangeBatch(
        protocolVersion: 1, sourceVault: first.sourceVault,
        sourceEpoch: first.sourceEpoch, after: first.after,
        changes: [changed], headSequence: first.headSequence)
    #expect(throws: AndesiteSyncError.contentMismatch) {
        try server.receiveSyncChanges(tampered)
    }
    let divergent = AndesiteSyncChangeBatch(
        protocolVersion: 1, sourceVault: first.sourceVault,
        sourceEpoch: first.sourceEpoch, after: 1,
        changes: first.changes, headSequence: second.headSequence)
    #expect(throws: AndesiteSyncError.historyGap) {
        try server.receiveSyncChanges(divergent)
    }
    try source.shutdown()
    try destination.shutdown()
    let restarted = try VaultRuntime(configuration: local.configuration)
    #expect(try restarted.syncAcknowledgedSequence(peer: peer) == second.through)
    // Closing the Vault can publish an additional recovery snapshot.
    // It must remain pending rather than be lost behind the change cursor.
    let pending = try restarted.pendingSyncSnapshots(peer: peer)
    #expect(!pending.contains(history.id))
    #expect(pending.count >= 1)
    try restarted.shutdown()
}

@Test func syncWireRejectsUnboundedBodiesAndUnmatchedAcknowledgements() throws {
    let source = try RuntimeFixture(); defer { source.clean() }
    try source.write("huge.md", "# Example\n" + String(repeating: "x", count: 150_000))
    let runtime = try VaultRuntime(configuration: source.configuration)
    _ = try runtime.reconcile()
    #expect(throws: AndesiteSyncError.artifactTooLarge) {
        try runtime.syncChanges(after: 0)
    }
    let newPeer = "id-with-no-credentials"
    #expect(try runtime.syncAcknowledgedSequence(peer: newPeer) == 0)
    #expect(throws: AndesiteSyncError.invalidPeer) {
        try runtime.syncAcknowledgedSequence(peer: "bad\npeer")
    }
    try runtime.shutdown()
}

@Test func syncHTTPTransportRequiresTLSOutsideLoopback() throws {
    let valid = String(repeating: "a", count: 64)
    #expect(throws: AndesiteSyncTransportError.insecureDestination) {
        try AndesiteHTTPSyncClient(
            destination: URL(string: "http://example.com")!, token: valid)
    }
    #expect(throws: AndesiteSyncTransportError.insecureDestination) {
        try AndesiteHTTPSyncClient(
            destination: URL(string: "https://user:pw@example.com")!, token: valid)
    }
    #expect(throws: AndesiteSyncTransportError.insecureDestination) {
        try AndesiteHTTPSyncClient(
            destination: URL(string: "https://example.com:443/other-path")!, token: valid)
    }
    #expect(throws: AndesiteSyncTransportError.invalidCredential) {
        try AndesiteHTTPSyncClient(
            destination: URL(string: "https://example.com")!, token: "password")
    }
    _ = try AndesiteHTTPSyncClient(
        destination: URL(string: "http://127.0.0.1:8788")!, token: valid)
    let client = try AndesiteHTTPSyncClient(
        destination: URL(string: "https://example.com")!, token: valid)
    #expect(try client.checkpointKey(peer: "work") == "work@https://example.com:443")
    let other = try AndesiteHTTPSyncClient(
        destination: URL(string: "https://backup.example.com")!, token: valid)
    #expect(try client.checkpointKey(peer: "work") !=
            other.checkpointKey(peer: "work"))
    #expect(throws: AndesiteSyncError.invalidPeer) {
        try client.checkpointKey(peer: "name\nother")
    }
}

@Test func embeddedSessionBackendDoesNotStartAnHTTPServerOrExtraOwner() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("embedded.md", "# Embedded\ntyped-backend\n")
    let session = try VaultSession(
        vaultDirectory: f.vault.path, stateDirectory: f.state.path)
    _ = try session.reconcile()
    let backend = try session.backend
    let page = try backend.documents()
    #expect(page.total == 1 && page.documents[0].path == "embedded.md")
    #expect(try backend.documentContents(page.documents[0].id)
            == Data("# Embedded\ntyped-backend\n".utf8))
    #expect(try backend.syncChanges(after: 0).changes.count == 1)
    try session.close()
    #expect(throws: VaultRuntimeError.closed) { try backend.documents() }
}
