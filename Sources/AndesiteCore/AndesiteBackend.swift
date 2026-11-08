import Foundation

/// The host-independent Andesite service interface. A macOS app, daemon,
/// command-line process or HTTP adapter calls these same operations. There
/// is no second SQLite owner, HTTP dependency or filesystem scanner here.
///
/// Owner-thread only, deliberately non-Sendable: retain one instance for the
/// life of the open VaultSession/VaultRuntime. Dispatch UI and network calls
/// onto the session's serial backend executor; never call from a SwiftUI
/// render pass, network event loop or a second thread.
public final class AndesiteBackend {
    private let owner: VaultRuntime

    public init(runtime: VaultRuntime) { self.owner = runtime }

    public var vaultID: Data { owner.vaultID }
    public var linksIndexed: Bool { owner.linksIndexed }
    public var linkCacheGeneration: Int { owner.linkCacheGeneration }
    public var linkCacheProgress:
        (processedHeads: Int, totalHeads: Int, resolvedHeads: Int)? {
        owner.linkCacheProgress
    }

    public func syncChanges(after: Int64, limit: Int = 8) throws
        -> AndesiteSyncChangeBatch {
        try owner.syncChanges(after: after, limit: limit)
    }
    public func syncSnapshot(_ id: Data) throws -> AndesiteSyncSnapshot {
        try owner.syncSnapshot(id)
    }
    @discardableResult
    public func receiveSyncChanges(_ batch: AndesiteSyncChangeBatch) throws
        -> AndesiteSyncReceipt {
        try owner.receiveSyncChanges(batch)
    }
    @discardableResult
    public func receiveSyncSnapshot(_ item: AndesiteSyncSnapshot) throws -> Bool {
        try owner.receiveSyncSnapshot(item)
    }
    public func pendingSyncSnapshots(peer: String, limit: Int = 50) throws -> [Data] {
        try owner.pendingSyncSnapshots(peer: peer, limit: limit)
    }
    public func acknowledgeSyncSnapshot(peer: String,
                                        snapshot: AndesiteSyncSnapshot) throws {
        try owner.acknowledgeSyncSnapshot(peer: peer, snapshot: snapshot)
    }

    public func syncInboxChanges(sourceVault: String, sourceEpoch: String,
                                 after: Int64, limit: Int = 8) throws
        -> AndesiteSyncChangeBatch {
        try owner.syncInboxChanges(sourceVault: sourceVault,
                                   sourceEpoch: sourceEpoch, after: after, limit: limit)
    }
    public func syncInboxSnapshot(sourceVault: String, sourceEpoch: String,
                                  snapshotID: String) throws -> AndesiteSyncSnapshot {
        try owner.syncInboxSnapshot(sourceVault: sourceVault,
                                    sourceEpoch: sourceEpoch, snapshotID: snapshotID)
    }
    public func syncInboxSnapshotList(sourceVault: String, sourceEpoch: String,
                                      limit: Int = 50, offset: Int = 0) throws
        -> [String: Any] {
        try owner.syncInboxSnapshotList(sourceVault: sourceVault,
                                        sourceEpoch: sourceEpoch, limit: limit,
                                        offset: offset)
    }

    public func syncInbox(limit: Int = 50, offset: Int = 0) throws -> [String: Any] {
        try owner.syncInbox(limit: limit, offset: offset)
    }

    public func syncAcknowledgedSequence(peer: String) throws -> Int64 {
        try owner.syncAcknowledgedSequence(peer: peer)
    }
    public func acknowledgeSync(peer: String, batch: AndesiteSyncChangeBatch,
                                receipt: AndesiteSyncReceipt) throws {
        try owner.acknowledgeSync(peer: peer, batch: batch, receipt: receipt)
    }

    public func status() throws -> VaultStatus { try owner.status() }
    public func reconcile() throws -> ReconciliationReport { try owner.reconcile() }
    public func documents(limit: Int = 50, offset: Int = 0,
                          filter: ObsidianFilter? = nil) throws -> DocumentPage {
        try owner.documents(limit: limit, offset: offset, filter: filter)
    }
    public func inspectDocument(_ id: Data) throws -> IndexedDocument {
        try owner.inspectDocument(id)
    }
    public func documentContents(_ id: Data, maximumBytes: Int = 1024 * 1024) throws -> Data {
        try owner.documentContents(id, maximumBytes: maximumBytes)
    }
    public func documentMetadata(_ id: Data) throws -> [String: Any] {
        try owner.documentMetadata(id)
    }
    public func tags(limit: Int = 50, offset: Int = 0) throws -> [String: Any] {
        try owner.tags(limit: limit, offset: offset)
    }
    public func properties(limit: Int = 50, offset: Int = 0) throws -> [String: Any] {
        try owner.properties(limit: limit, offset: offset)
    }
    public func searchIndexed(_ phrase: String, limit: Int = 50,
                              filter: ObsidianFilter? = nil) throws -> [SearchIndexHit] {
        try owner.searchIndexed(phrase, limit: limit, filter: filter)
    }
    public func links(_ id: Data, direction: VaultLinkDirection,
                      limit: Int = 50, offset: Int = 0) throws -> VaultLinkPage {
        try owner.links(id, direction: direction, limit: limit, offset: offset)
    }
    public func snapshots(entryID: Data? = nil, path: String? = nil) throws -> [RecoverySnapshot] {
        try owner.snapshots(entryID: entryID, path: path)
    }
    public func inspectSnapshot(_ id: Data) throws -> RecoverySnapshot {
        try owner.inspectSnapshot(id)
    }
    public func snapshotContents(_ id: Data) throws -> Data { try owner.snapshotContents(id) }
    public func snapshotPolicy() throws -> SnapshotPolicy { try owner.snapshotPolicy() }
    public func configureSnapshots(_ policy: SnapshotPolicy) throws {
        try owner.configureSnapshots(policy)
    }
    public func snapshotStorage(at date: Date = Date()) throws -> SnapshotStorageUsage {
        try owner.snapshotStorage(at: date)
    }
    public func compareSnapshots(_ before: Data, _ after: Data) throws -> SnapshotComparison {
        try owner.compareSnapshots(before, after)
    }
    public func exportSnapshot(_ id: Data, to destination: String) throws {
        try owner.exportSnapshot(id, to: destination)
    }
    public func mutationOperations() throws -> [MutationOperation] {
        try owner.mutationOperations()
    }
    public func inspectMutation(_ id: Data) throws -> MutationInspection {
        try owner.inspectMutation(id)
    }
    @discardableResult
    public func resolveMutation(_ id: Data, strategy: String) throws -> MutationOperation {
        try owner.resolveMutation(id, strategy: strategy)
    }
    public func exportMutationVersion(_ id: Data, role: String,
                                      to destination: String) throws {
        try owner.exportMutationVersion(id, role: role, to: destination)
    }
    @discardableResult
    public func editDocument(_ id: Data, expectedRevision: Data,
                             contents: Data) throws -> MutationOperation {
        try owner.editDocument(id, expectedRevision: expectedRevision, contents: contents)
    }
    @discardableResult
    public func restoreSnapshot(_ id: Data) throws -> MutationOperation {
        try owner.restoreSnapshot(id)
    }
}
