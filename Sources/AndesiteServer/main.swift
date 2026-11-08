import Foundation
import AndesiteCore

// Local-only CLI. Only watch starts a private same-user Unix-domain HTTP socket.
enum CLIError: Error { case usage; case invalidIdentifier; case invalidPolicy }
func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func identifier(_ text: String) throws -> Data {
    let value = text.replacingOccurrences(of: "-", with: "").lowercased()
    guard value.utf8.count == 32, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CLIError.invalidIdentifier }
    return Data(stride(from: 0, to: 32, by: 2).map { offset in
        let start = value.index(value.startIndex, offsetBy: offset)
        return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
    })
}
func describe(_ snapshot: RecoverySnapshot) -> String {
    let formatter = ISO8601DateFormatter()
    return "snapshot=\(hex(snapshot.id)) document=\(hex(snapshot.entryID)) state=\(snapshot.documentState) path=\(snapshot.originalPath) created=\(formatter.string(from: snapshot.createdAt)) expires=\(formatter.string(from: snapshot.expiresAt)) eligible=\(snapshot.isExpired()) reason=\(snapshot.reason) hash=\(snapshot.contentHash) bytes=\(snapshot.byteLength) revision=\(hex(snapshot.revisionID)) observed=\(snapshot.observedAt)"
}
let usage = """
Usage: andesite-server <command> --vault /absolute/vault --state /absolute/private-state [arguments]
  vault-list                        (show selected paths from ~/.andesite/vaults.json)
  vault-add /absolute/vault         (remember selected path without scanning)
  vault-remove /absolute/vault      (forget path without changing vault or history)
  init | reconcile | status | search <phrase>
  watch    (macOS FSEvents plus read-only HTTP on state/andesite-read.sock; SIGINT/SIGTERM to stop)
  snapshots [document-id-or-historical-path]
  snapshot-inspect <snapshot-id>
  snapshot-compare <before-id> <after-id>
  snapshot-export <snapshot-id> /absolute/new-file-outside-vault-and-state
  snapshot-restore <snapshot-id> --in-place
  mutation-journal    (all operations, including conflicts and recovery outcomes)
  mutation-inspect <operation-id>
  mutation-resolve <operation-id> --strategy <accept-current|preserve-current|complete-published|cancel-unpublished>
  mutation-export <operation-id> <intended|preimage|current|artifact|path-occupant|retirement|sha256:HASH> /absolute/new-file
  mutation-artifacts
  mutation-cleanup --dry-run | --retire  (stop external editors before --retire)
  snapshot-storage
  snapshot-config <minimum-interval-seconds> <retention-seconds>
Directories must already exist; state must be mode 0700. No TCP listener.
Snapshot expiration is metadata only; no snapshots, revisions or objects are pruned.
"""
let args = Array(CommandLine.arguments.dropFirst())
do {
    if let command = args.first, ["vault-list", "vault-add", "vault-remove"].contains(command) {
        let expected = command == "vault-list" ? 1 : 2
        guard args.count == expected else { throw CLIError.usage }
        let registry = try VaultPathRegistry()
        switch command {
        case "vault-list":
            for path in try registry.list() { print(path) }
        case "vault-add":
            print(try registry.add(args[1]) ? "Saved vault path: \(args[1])" : "Already registered: \(args[1])")
        default:
            print(try registry.remove(args[1]) ? "Removed saved path: \(args[1])" : "Not registered: \(args[1])")
        }
    } else {
    let counts: [String: ClosedRange<Int>] = ["init": 0...0, "reconcile": 0...0, "status": 0...0, "search": 1...1, "watch": 0...0,
        "snapshots": 0...1, "snapshot-inspect": 1...1, "snapshot-compare": 2...2, "snapshot-export": 2...2,
        "snapshot-restore": 2...2, "snapshot-storage": 0...0, "mutation-journal": 0...0, "snapshot-config": 2...2, "mutation-inspect": 1...1, "mutation-resolve": 3...3, "mutation-export": 3...3, "mutation-artifacts": 0...0, "mutation-cleanup": 1...1]
    guard args.count >= 5, let count = counts[args[0]], count.contains(args.count - 5), args[1] == "--vault", args[3] == "--state" else { throw CLIError.usage }
    if args[0] == "snapshot-restore", args[6] != "--in-place" { throw CLIError.usage }
    let runtime = try VaultRuntime(configuration: VaultConfiguration(vaultDirectory: args[2], stateDirectory: args[4]))
    do {
        switch args[0] {
        case "init", "reconcile":
            let report = try runtime.reconcile()
            print("discovered=\(report.discovered) revisionsCreated=\(report.revisionsCreated) unchanged=\(report.unchanged) invalidMarkdown=\(report.invalidMarkdown) deleted=\(report.deleted) renamed=\(report.renamed) snapshotsCreated=\(report.snapshotsCreated)")
        case "watch":
            #if os(macOS)
            // The API and watcher share one synchronous owner; neither
            // opens a second database connection or a TCP listening port.
            VaultMonitor.installTerminationHandlers()
            let monitor = try VaultMonitor(runtime: runtime, vaultDirectory: args[2])
            let api = try VaultLocalHTTP(runtime: runtime, stateDirectory: args[4])
            FileHandle.standardOutput.write(Data(
                "watch-api socket=\(api.socketPath) transport=unix-http access=same-user\n".utf8))
            try monitor.run(onIdle: { ready in
                try api.poll(indexReady: ready)
            }, report: { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            })
            #else
            throw CLIError.usage
            #endif
        case "search":
            for hit in try runtime.search(args[5]) { print("\(hex(hit.entryID))\t\(hit.title)") }
        case "snapshots":
            let snapshots: [RecoverySnapshot]
            if args.count == 5 { snapshots = try runtime.snapshots() }
            else if let id = try? identifier(args[5]) { snapshots = try runtime.snapshots(entryID: id) }
            else { snapshots = try runtime.snapshots(path: args[5]) }
            for snapshot in snapshots { print(describe(snapshot)) }
        case "snapshot-inspect":
            let id = try identifier(args[5])
            var output = Data((describe(try runtime.inspectSnapshot(id)) + "\n--- contents ---\n").utf8)
            output.append(try runtime.snapshotContents(id))
            FileHandle.standardOutput.write(output)
        case "snapshot-compare":
            let comparison = try runtime.compareSnapshots(identifier(args[5]), identifier(args[6]))
            print("--- \(hex(comparison.before.id))\n+++ \(hex(comparison.after.id))")
            for change in comparison.changes { print(change) }
        case "snapshot-export":
            try runtime.exportSnapshot(identifier(args[5]), to: args[6])
            print("Exported verified bytes without overwriting: \(args[6])")
        case "snapshot-restore":
            let op = try runtime.restoreSnapshot(identifier(args[5]))
            print("Restored document=\(hex(op.entryID)) path=\(op.path) snapshot=\(hex(op.snapshotID)) preimage=\(hex(op.preimageID)) revision=\(hex(op.revisionID)) operation=\(hex(op.id)) state=\(op.state)")
        case "mutation-inspect":
            let inspection = try runtime.inspectMutation(identifier(args[5]))
            let op = inspection.operation
            print("operation=\(hex(op.id)) state=\(op.state) document=\(hex(op.entryID)) path=\(op.path) snapshot=\(hex(op.snapshotID)) preimage=\(hex(op.preimageID)) revision=\(hex(op.revisionID)) strategy=\(inspection.strategy ?? "none") outcome=\(inspection.outcome ?? "none")")
            print("parentRevision=\(hex(inspection.parentRevision)) expectedOriginal=\(inspection.expectedOriginal) expectedStage=\(inspection.expectedStage.map { String(describing: $0) } ?? "none") previousDecisions=\(inspection.previousDecisions)")
            for event in inspection.audit { print("decision=\(event)") }
            for version in inspection.versions {
                print("version=\(version.role) path=\(version.path) hash=\(version.hash) bytes=\(version.bytes) identity=\(version.fingerprint.map { String(describing: $0) } ?? "immutable")")
            }
            for diagnostic in inspection.diagnostics { print("diagnostic=\(diagnostic)") }
            print("choices=\(inspection.choices.joined(separator: ",")) export=mutation-export")
        case "mutation-resolve":
            guard args[6] == "--strategy" else { throw CLIError.usage }
            let op = try runtime.resolveMutation(identifier(args[5]), strategy: args[7])
            print("operation=\(hex(op.id)) state=\(op.state) outcome=\(op.diagnostic)")
        case "mutation-export":
            try runtime.exportMutationVersion(identifier(args[5]), role: args[6], to: args[7])
            print("Exported verified version without overwriting: \(args[7])")
        case "mutation-artifacts", "mutation-cleanup":
            let artifacts: [MutationArtifact]
            if args[0] == "mutation-cleanup" {
                guard ["--dry-run", "--retire"].contains(args[5]) else { throw CLIError.usage }
                artifacts = try runtime.cleanupMutationArtifacts(dryRun: args[5] == "--dry-run")
            } else { artifacts = try runtime.mutationArtifacts() }
            for a in artifacts { print("operation=\(hex(a.operationID)) path=\(a.path) status=\(a.status) logicalBytes=\(a.status == "uncertain" ? "unknown" : String(a.logicalBytes)) allocatedBytes=\(a.status == "uncertain" ? "unknown" : String(a.allocatedBytes)) eligible=\(a.eligible) diagnostic=\(a.diagnostic)") }
            print("artifactAllocatedBytes=\(artifacts.reduce(0) { $0 + $1.allocatedBytes }) retirementEligibleAllocatedBytes=\(artifacts.filter(\.eligible).reduce(0) { $0 + $1.allocatedBytes }) retainedAllocatedBytes=\(artifacts.filter { !$0.eligible }.reduce(0) { $0 + $1.allocatedBytes }) uncertain=\(artifacts.filter { $0.status == "uncertain" }.count)")
        case "mutation-journal":
            let operations = try runtime.mutationOperations()
            for op in operations {
                print("operation=\(hex(op.id)) document=\(hex(op.entryID)) path=\(op.path) snapshot=\(hex(op.snapshotID)) preimage=\(hex(op.preimageID)) revision=\(hex(op.revisionID)) state=\(op.state) artifact=\(op.artifact) diagnostic=\(op.diagnostic)")
            }
            print("operations=\(operations.count) unfinished=\(operations.filter { !["completed", "cancelled"].contains($0.state) }.count)")
            let maintenance = try runtime.status()
            print("vaultState=\(maintenance.state) maintenanceUnfinished=\(maintenance.unfinishedMutations)")
        case "snapshot-config":
            guard let interval = Double(args[5]), let retention = Double(args[6]) else { throw CLIError.invalidPolicy }
            try runtime.configureSnapshots(SnapshotPolicy(minimumInterval: interval, retentionSeconds: retention))
            print("Saved policy for new snapshots; existing expiration deadlines unchanged.")
        case "snapshot-storage":
            let storage = try runtime.snapshotStorage()
            print("minimumIntervalSeconds=\(storage.policy.minimumInterval) retentionSeconds=\(storage.policy.retentionSeconds) snapshots=\(storage.snapshots) expirationEligible=\(storage.expirationEligible) pendingDocuments=\(storage.pendingDocuments) logicalBytes=\(storage.logicalBytes) uniqueSnapshotBytes=\(storage.uniqueSnapshotBytes) registeredObjectBytes=\(storage.registeredObjectBytes) automaticPruning=false")
            print("immutableObjectLogicalBytes=\(storage.immutableObjectLogicalBytes) physicalObjectAllocatedBytes=\(storage.physicalObjectAllocatedBytes) temporaryObjectAllocatedBytes=\(storage.temporaryObjectAllocatedBytes) journalArtifactAllocatedBytes=\(storage.artifactAllocatedBytes) retirementEligibleAllocatedBytes=\(storage.retirementEligibleAllocatedBytes) unresolvedArtifactAllocatedBytes=\(storage.unresolvedArtifactAllocatedBytes) uncertainArtifacts=\(storage.uncertainArtifacts) artifactAccountingComplete=\(storage.uncertainArtifacts == 0) physicalNumbersAreAllocatedBlockEstimates=true snapshotLogicalBytesAreNotAdditionalPhysicalUsage=true")
            for object in storage.objects {
                print("\(object.contentHash) bytes=\(object.byteLength) snapshots=\(object.snapshots) revisions=\(object.revisions) incidents=\(object.incidents) mutationVersions=\(object.mutationVersions)")
            }
        default:
            let status = try runtime.status()
            print("vault=\(hex(status.vaultID)) state=\(status.state) entries=\(status.entries) revisions=\(status.revisions) openIncidents=\(status.openIncidents) unfinishedMutations=\(status.unfinishedMutations)")
        }
        try runtime.shutdown()
    } catch {
        let operationError = error
        do { try runtime.shutdown() }
        catch { FileHandle.standardError.write(Data("Snapshot flush also failed (captured revisions retained): \(error)\n".utf8)) }
        throw operationError
    }
    }
} catch {
    FileHandle.standardError.write(Data("Andesite refused operation: \(error)\n".utf8))
    if error is CLIError { FileHandle.standardError.write(Data((usage + "\n").utf8)) }
    exit(1)
}
